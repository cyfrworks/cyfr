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

  ## AAD reconstruction (must mirror the callers)

  The cipher binds the row's canonical tenant tuple as AAD. This module
  rebuilds that tuple from each row's stored columns; the shapes here MUST
  stay identical to how `Sanctum.Vault` and `Sanctum.Webhook` persist them
  (the org/project values the storage layer persists are already normalized,
  so re-normalizing is idempotent).
  """

  require Logger
  require Arca.Repo.Errors
  import Ecto.Query

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
  registry_tokens: summary, dry_run: bool}}` or `{:error, {table,
  reason, sample_id}}` (the run aborted fail-closed; rerun after fixing the
  cause — already-rotated rows are skipped).
  """
  @spec reencrypt_all(keyword()) :: {:ok, map()} | {:error, {atom(), term(), term()}}
  def reencrypt_all(opts \\ []) do
    ensure_started()
    dry = Keyword.get(opts, :dry_run, false)

    with {:ok, w} <- rotate_table(:webhooks, opts),
         {:ok, v} <- rotate_table(:vault_entries, opts),
         {:ok, r} <- rotate_table(:registry_tokens, opts) do
      result = %{
        webhooks: w,
        vault_entries: v,
        registry_tokens: r,
        dry_run: dry
      }

      :telemetry.execute([:cyfr, :crypto_rotation, :run], %{count: 1}, result)
      {:ok, result}
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

    report =
      Map.new(
        [
          {:webhooks, :secret_encrypted},
          {:vault_entries, :sealed_payload},
          {:registry_tokens, :credential_ciphertext}
        ],
        fn {table, col} ->
          {table, audit_table(table, col, primary)}
        end
      )

    {:ok, report}
  end

  # ==========================================================================
  # Per-table rotation (keyset pagination by id — bounded memory, resumable)
  # ==========================================================================

  defp rotate_table(table, opts) do
    batch = Keyword.get(opts, :batch_size, @batch)
    acc = %{scanned: 0, rotated: 0, skipped: 0}

    case page(table, nil, batch, acc, opts) do
      {:ok, summary} ->
        :telemetry.execute([:cyfr, :crypto_rotation, :table], summary, %{table: table})
        {:ok, summary}

      {:error, _} = err ->
        err
    end
  end

  defp page(table, cursor, batch, acc, opts) do
    rows = fetch_page(table, cursor, batch)

    case rows do
      [] ->
        {:ok, acc}

      _ ->
        case reduce_rows(table, rows, acc, opts) do
          {:ok, acc2} ->
            last_id = rows |> List.last() |> Map.fetch!(:id)
            page(table, last_id, batch, acc2, opts)

          {:error, _} = err ->
            err
        end
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[CryptoRotation] #{table} DB error: #{Exception.message(e)}")
      {:error, {table, :database_error, cursor}}
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
    aad = Sanctum.CipherAAD.webhook_secret(row.scope_type, row.org_id, row.project_id, row.name)

    cols =
      [{:secret_encrypted, row.sec, aad}] ++
        if is_binary(row.prev), do: [{:previous_secret_encrypted, row.prev, aad}], else: []

    rotate_columns(:webhooks, row.id, cols, opts, fn -> :ok end)
  end

  defp rotate_row(:vault_entries, row, opts) do
    aad = Sanctum.CipherAAD.vault_entry(row.org_id, row.project_id, row.id, row.provider_hint)

    rotate_columns(:vault_entries, row.id, [{:sealed_payload, row.ct, aad}], opts, fn -> :ok end)
  end

  defp rotate_row(:registry_tokens, row, opts) do
    aad = Sanctum.CipherAAD.registry_token(row.user_id, row.registry, row.namespace_slug)

    rotate_columns(
      :registry_tokens,
      row.id,
      [{:credential_ciphertext, row.ct, aad}],
      opts,
      fn -> :ok end
    )
  end

  # Skip the row iff every ciphertext column is already on the primary label;
  # otherwise re-encrypt the lagging columns and commit them together with one
  # compare-and-swap keyed on the row's *current* primary-secret ciphertext.
  defp rotate_columns(table, id, cols, opts, invalidate) do
    primary = Cipher.primary_label()

    case classify(cols, primary) do
      {:error, _} = err ->
        err

      {:skip} ->
        {:ok, :skipped}

      {:rotate, planned} ->
        if Keyword.get(opts, :dry_run, false) do
          :telemetry.execute([:cyfr, :crypto_rotation, :row], %{count: 1}, %{
            table: table,
            id: id,
            result: :would_rotate
          })

          {:ok, :rotated}
        else
          commit(table, id, cols, planned, invalidate)
        end
    end
  end

  # planned: %{col => new_ct} for columns that needed rotation. A column is
  # finished only when it is already sealed on the primary key.
  defp classify(cols, primary) do
    Enum.reduce_while(cols, {:skip}, fn {col, ct, aad}, state ->
      case Cipher.envelope(ct) do
        {:ok, {3, ^primary}} ->
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

  defp merge_plan({:skip}, col, ct), do: {:rotate, %{col => ct}}
  defp merge_plan({:rotate, m}, col, ct), do: {:rotate, Map.put(m, col, ct)}

  defp commit(table, id, cols, planned, invalidate) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    [{cas_col, cas_old, _} | _] = cols
    set = planned |> Map.to_list() |> Keyword.put(:updated_at, now)

    q =
      from(r in schema_for(table),
        where: r.id == ^id and field(r, ^cas_col) == ^cas_old
      )

    case Arca.Repo.update_all(q, set: set) do
      {1, _} ->
        invalidate.()

        :telemetry.execute([:cyfr, :crypto_rotation, :row], %{count: 1}, %{
          table: table,
          id: id,
          result: :rotated
        })

        {:ok, :rotated}

      {0, _} ->
        # A concurrent legitimate write changed the row (it now holds a
        # primary-key ciphertext). Treat as skipped; a later pass confirms.
        :telemetry.execute([:cyfr, :crypto_rotation, :row], %{count: 1}, %{
          table: table,
          id: id,
          result: :cas_miss
        })

        {:ok, :skipped}
    end
  end

  # ==========================================================================
  # Queries
  # ==========================================================================

  defp fetch_page(:webhooks, cursor, batch) do
    base(cursor, batch, Arca.Schemas.Webhook)
    |> select([r], %{
      id: r.id,
      name: r.name,
      scope_type: r.scope_type,
      org_id: r.org_id,
      project_id: r.project_id,
      sec: r.secret_encrypted,
      prev: r.previous_secret_encrypted
    })
    |> Arca.Repo.all()
  end

  defp fetch_page(:vault_entries, cursor, batch) do
    base(cursor, batch, Arca.Schemas.VaultEntry)
    |> where([r], not is_nil(r.sealed_payload))
    |> select([r], %{
      id: r.id,
      org_id: r.org_id,
      project_id: r.project_id,
      provider_hint: r.provider_hint,
      ct: r.sealed_payload
    })
    |> Arca.Repo.all()
  end

  defp fetch_page(:registry_tokens, cursor, batch) do
    base(cursor, batch, Arca.Schemas.RegistryToken)
    |> select([r], %{
      id: r.id,
      user_id: r.user_id,
      registry: r.registry,
      namespace_slug: r.namespace_slug,
      ct: r.credential_ciphertext
    })
    |> Arca.Repo.all()
  end

  defp base(nil, batch, schema) do
    from(r in schema, order_by: [asc: r.id], limit: ^batch)
  end

  defp base(cursor, batch, schema) do
    from(r in schema, where: r.id > ^cursor, order_by: [asc: r.id], limit: ^batch)
  end

  defp schema_for(:webhooks), do: Arca.Schemas.Webhook
  defp schema_for(:vault_entries), do: Arca.Schemas.VaultEntry
  defp schema_for(:registry_tokens), do: Arca.Schemas.RegistryToken

  defp audit_table(table, col, primary) do
    # nil excluded for tombstoned vault entries; the other ciphertext columns
    # are non-null, so the filter is a no-op there.
    rows =
      from(r in schema_for(table), where: not is_nil(field(r, ^col)), select: field(r, ^col))
      |> Arca.Repo.all()

    Enum.reduce(rows, %{total: 0, on_primary: 0, on_other: %{}, unknown: 0}, fn ct, a ->
      a = %{a | total: a.total + 1}

      case Cipher.label(ct) do
        {:ok, ^primary} -> %{a | on_primary: a.on_primary + 1}
        {:ok, other} -> %{a | on_other: Map.update(a.on_other, other, 1, &(&1 + 1))}
        :error -> %{a | unknown: a.unknown + 1}
      end
    end)
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[CryptoRotation] audit #{table} DB error: #{Exception.message(e)}")
      %{error: :database_error}
  end

  defp ensure_started do
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(:cyfr)
    :ok
  end
end
