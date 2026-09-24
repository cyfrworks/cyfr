# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Cipher.Rotation do
  @moduledoc """
  Key-rotation / re-encryption tooling for `Sanctum.Cipher`.

  Operator-driven and adapter-agnostic — the batched keyset walk runs the
  same against SQLite and Postgres. Re-encrypts every at-rest credential
  blob onto the current keyring primary so a
  retired key can be safely dropped.

  ## Usage

      bin/cyfr eval "Sanctum.Cipher.Rotation.audit()"
      bin/cyfr eval "Sanctum.Cipher.Rotation.reencrypt_all(dry_run: true)"
      bin/cyfr eval "Sanctum.Cipher.Rotation.reencrypt_all()"

  ## Three-phase rotation

  1. Add the new key to `CYFR_CRYPTO_KEYRING`, point `primary` at it, redeploy.
     The system keeps working with mixed labels (old keys still decrypt).
  2. `reencrypt_all/1` — per row: skip only when the row is already on
     `primary` (idempotent, resumable). Otherwise decrypt with the embedded label and
     re-encrypt under `primary`, rebuilding the AAD from the row's own tenant
     columns. The update is an in-place compare-and-swap on the exact old
     ciphertext, so a concurrent legitimate write is never clobbered. Any row
     that fails to decrypt aborts the run (fail closed) — a silently skipped
     row would become permanently undecryptable once the old key is dropped.
  3. `audit/0` — assert every row is on a key still in the keyring (and report
     anything not yet on `primary`) before the operator removes the old key.

  Vault entries rotate with everything else; tombstoned rows (`sealed_payload`
  erased) are excluded by query. Re-sealing never touches `payload_rev` — that
  column is the material CAS token, and a concurrent `vault.rotate` must not
  fail because an encryption pass rewrote unchanged material.

  ## Where the halves live

  The rows are `Arca.CipherRotation`'s: it holds the table roster, the
  keyset pages and the compare-and-set write, and it is asked as the
  server (`Prima.Actor.system/0`) because a rotation retires a key across
  every athanor at once. Nothing below this module sees a key or a
  plaintext — `classify/3` decrypts and re-seals in this process and hands
  ciphertext down.

  ## AAD reconstruction (must mirror the callers)

  The cipher binds the row's canonical tenant tuple as AAD. This module
  rebuilds that tuple from each row's stored columns; the shapes here MUST
  stay identical to how `Sanctum.Vault`, `Sanctum.Webhook` and
  `Sanctum.ProviderCredentials` persist them (the athanor id the storage
  layer persists is bound through unchanged). Every `Sanctum.CipherAAD`
  purpose has a `rotate_row/3` clause here — the roster test pins the two
  lists together.
  """

  require Logger

  alias Sanctum.Cipher

  @batch 500

  @type summary :: %{
          scanned: non_neg_integer(),
          rotated: non_neg_integer(),
          skipped: non_neg_integer()
        }

  @doc """
  Re-encrypt every credential blob onto the keyring primary.

  Options: `:dry_run` (default `false`) — report what would change, write
  nothing; `:batch_size` (default #{@batch}).

  Returns `{:ok, %{webhooks: summary, vault_entries: summary,
  registry_tokens: summary, oauth_provider_credentials: summary,
  dry_run: bool}}` or `{:error, {table, reason, sample_id}}` (the run
  aborted fail-closed; rerun after fixing the cause — already-rotated rows
  are skipped).
  """
  @spec reencrypt_all(keyword()) :: {:ok, map()} | {:error, {atom(), term(), term()}}
  def reencrypt_all(opts \\ []) do
    ensure_started()
    dry = Keyword.get(opts, :dry_run, false)

    tables()
    |> Enum.reduce_while({:ok, %{dry_run: dry}}, fn table, {:ok, acc} ->
      case rotate_table(table, opts) do
        {:ok, summary} -> {:cont, {:ok, Map.put(acc, table, summary)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, result} ->
        :telemetry.execute([:cyfr, :sanctum, :crypto_rotation, :run], %{count: 1}, result)
        {:ok, result}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Report the key-label distribution across all credential tables without
  decrypting. Returns `{:ok, %{table => %{total, on_primary, on_other:
  %{label => count}, unknown: count}}}`. `unknown > 0` or any `on_other` label
  not in the keyring means it is NOT yet safe to retire that key.
  """
  @spec audit() :: {:ok, map()}
  def audit do
    ensure_started()
    primary = Cipher.primary_label()

    {:ok, Map.new(tables(), fn table -> {table, audit_table(table, primary)} end)}
  end

  # The one roster: every credential table with sealed rows. It lives
  # below, beside the schemas it names, and `rotate_row/3` must have a
  # clause for each of them — a table with no clause fails loudly on its
  # first row rather than being walked past.
  defp tables, do: Arca.CipherRotation.tables()

  defp actor, do: Prima.Actor.system()

  # ==========================================================================
  # Per-table rotation (keyset pagination by id — bounded memory, resumable)
  # ==========================================================================

  defp rotate_table(table, opts) do
    batch = Keyword.get(opts, :batch_size, @batch)
    acc = %{scanned: 0, rotated: 0, skipped: 0}

    case page(table, nil, batch, acc, opts) do
      {:ok, summary} ->
        :telemetry.execute([:cyfr, :sanctum, :crypto_rotation, :table], summary, %{table: table})
        {:ok, summary}

      {:error, _} = err ->
        err
    end
  end

  # One page at a time, resuming from the last id seen. A store that
  # cannot answer ends the run with the cursor it stopped at, so a rerun
  # picks up there instead of walking the table again.
  defp page(table, cursor, batch, acc, opts) do
    case Arca.CipherRotation.page(actor(), table, cursor, batch) do
      {:ok, []} ->
        {:ok, acc}

      {:ok, rows} ->
        case reduce_rows(table, rows, acc, opts) do
          {:ok, acc2} ->
            last_id = rows |> List.last() |> Map.fetch!(:id)
            page(table, last_id, batch, acc2, opts)

          {:error, _} = err ->
            err
        end

      {:error, reason} ->
        Logger.error("[Cipher.Rotation] #{table} store error: #{inspect(reason)}")
        {:error, {table, reason, cursor}}
    end
  end

  defp reduce_rows(table, rows, acc, opts) do
    Enum.reduce_while(rows, {:ok, acc}, fn row, {:ok, a} ->
      case rotate_row(table, row, opts) do
        {:ok, outcome} ->
          {:cont, {:ok, bump(a, outcome)}}

        {:error, reason} ->
          {:halt, {:error, {table, reason, row.id}}}
      end
    end)
  end

  defp bump(a, :skipped), do: %{a | scanned: a.scanned + 1, skipped: a.skipped + 1}
  defp bump(a, :rotated), do: %{a | scanned: a.scanned + 1, rotated: a.rotated + 1}

  # ==========================================================================
  # Per-row rotation
  # ==========================================================================

  defp rotate_row(:webhooks, row, opts) do
    aad = Sanctum.CipherAAD.webhook_secret(row.athanor_id, row.name)

    rotate_columns(:webhooks, row, aad, opts)
  end

  defp rotate_row(:vault_entries, row, opts) do
    aad = Sanctum.CipherAAD.vault_entry(row.athanor_id, row.id, row.provider_hint)

    rotate_columns(:vault_entries, row, aad, opts)
  end

  defp rotate_row(:registry_tokens, row, opts) do
    aad = Sanctum.CipherAAD.registry_token(row.user_id, row.registry, row.namespace_slug)

    rotate_columns(:registry_tokens, row, aad, opts)
  end

  defp rotate_row(:oauth_provider_credentials, row, opts) do
    aad = Sanctum.CipherAAD.provider_credential(row.athanor_id, row.provider)

    rotate_columns(:oauth_provider_credentials, row, aad, opts)
  end

  # Skip the row iff every ciphertext column is already on the primary label;
  # otherwise re-encrypt the lagging columns and commit them together with one
  # compare-and-swap keyed on the row's *current* primary-secret ciphertext.
  defp rotate_columns(table, row, aad, opts) do
    primary = Cipher.primary_label()

    case classify(row.ciphertexts, aad, primary) do
      {:error, _} = err ->
        err

      :skip ->
        {:ok, :skipped}

      {:rotate, planned} ->
        if Keyword.get(opts, :dry_run, false) do
          emit(table, row.id, :would_rotate)
          {:ok, :rotated}
        else
          commit(table, row, planned)
        end
    end
  end

  # planned: %{col => new_ct} for columns that needed rotation. A column is
  # finished only when it is already sealed on the primary key in the current
  # envelope version. Keys and plaintext stay in this function: what leaves
  # it is a map of re-sealed ciphertext.
  defp classify(ciphertexts, aad, primary) do
    current = Cipher.current_version()

    Enum.reduce_while(ciphertexts, :skip, fn {col, ct}, state ->
      case Cipher.envelope(ct) do
        {:ok, {^current, ^primary}} ->
          {:cont, state}

        {:ok, {_version, _label}} ->
          case Cipher.decrypt(ct, aad) do
            {:ok, plain} ->
              # encrypt/2 returns {:ok, _} or raises on keyring misconfig
              # (correct loud fail-closed for an operator-run task — it never
              # returns {:error, _}).
              {:ok, new_ct} = Cipher.encrypt(plain, aad)
              {:cont, merge_plan(state, col, new_ct)}

            {:error, reason} ->
              {:halt, {:error, {:decrypt_failed, col, reason}}}
          end

        :error ->
          {:halt, {:error, {:not_a_cipher_envelope, col}}}
      end
    end)
  end

  defp merge_plan(:skip, col, ct), do: {:rotate, %{col => ct}}
  defp merge_plan({:rotate, m}, col, ct), do: {:rotate, Map.put(m, col, ct)}

  # The compare-and-set token is the ciphertext this row's page read in the
  # table's CAS column, which `Arca.CipherRotation` puts at the head of
  # `ciphertexts`. A miss means a concurrent legitimate write changed the
  # row; it is counted as skipped and reported, never as rotated, and a
  # later pass confirms it.
  defp commit(table, row, planned) do
    [{_cas_column, cas} | _] = row.ciphertexts

    case Arca.CipherRotation.swap(actor(), table, row.id, cas, planned) do
      {:ok, :swapped} ->
        emit(table, row.id, :rotated)
        {:ok, :rotated}

      {:ok, :stale} ->
        emit(table, row.id, :cas_miss)
        {:ok, :skipped}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp emit(table, id, result) do
    :telemetry.execute([:cyfr, :sanctum, :crypto_rotation, :row], %{count: 1}, %{
      table: table,
      id: id,
      result: result
    })
  end

  # ==========================================================================
  # Audit
  # ==========================================================================

  defp audit_table(table, primary) do
    tally(table, nil, %{total: 0, on_primary: 0, on_other: %{}, unknown: 0}, primary)
  end

  # Paged by the same cursor the rotation uses: an operator report over a
  # credential table is still a walk of every athanor's rows, and reading
  # it in one statement would be an unbounded read.
  #
  # Deliberate default: the audit is a read-only operator report — a table
  # the store cannot answer renders as an errored section, nothing acts on it.
  defp tally(table, cursor, acc, primary) do
    case Arca.CipherRotation.ciphertext_page(actor(), table, cursor, @batch) do
      {:ok, []} ->
        acc

      {:ok, rows} ->
        acc = Enum.reduce(rows, acc, &count_label(&1.ciphertext, &2, primary))
        tally(table, rows |> List.last() |> Map.fetch!(:id), acc, primary)

      {:error, reason} ->
        Logger.error("[Cipher.Rotation] #{table} audit store error: #{inspect(reason)}")
        %{error: :database_error}
    end
  end

  defp count_label(ct, acc, primary) do
    acc = %{acc | total: acc.total + 1}

    case Cipher.label(ct) do
      {:ok, ^primary} -> %{acc | on_primary: acc.on_primary + 1}
      {:ok, other} -> %{acc | on_other: Map.update(acc.on_other, other, 1, &(&1 + 1))}
      :error -> %{acc | unknown: acc.unknown + 1}
    end
  end

  defp ensure_started do
    {:ok, _} = Application.ensure_all_started(:ssl)
    # The rows are Arca's and the keyring is this application's; nothing
    # above either has to be running to re-encrypt.
    {:ok, _} = Application.ensure_all_started(:sanctum)
    :ok
  end
end
