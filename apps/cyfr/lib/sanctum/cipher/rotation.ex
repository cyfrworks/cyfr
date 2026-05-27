# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Cipher.Rotation do
  @moduledoc """
  Key-rotation / re-encryption tooling for `Sanctum.Cipher`.

  Operator-driven, Postgres-only (multi-row UPDATE semantics don't apply to
  single-user SQLite deployments). Re-encrypts every at-rest credential blob
  onto the current keyring primary so a retired key can be safely dropped.

  ## Usage

      bin/cyfr eval "Sanctum.Cipher.Rotation.audit()"
      bin/cyfr eval "Sanctum.Cipher.Rotation.reencrypt_all(dry_run: true)"
      bin/cyfr eval "Sanctum.Cipher.Rotation.reencrypt_all()"

  ## Three-phase rotation

  1. Add the new key to `CYFR_CRYPTO_KEYRING`, point `primary` at it, redeploy.
     The system keeps working with mixed labels (old keys still decrypt).
  2. `reencrypt_all/1` — per row: skip if already on `primary` (idempotent,
     resumable), else decrypt with the embedded label and re-encrypt under
     `primary`, rebuilding the AAD from the row's own tenant columns. The
     update is an in-place compare-and-swap on the exact old ciphertext, so a
     concurrent legitimate write is never clobbered. Any row that fails to
     decrypt aborts the run (fail closed) — a silently skipped row would
     become permanently undecryptable once the old key is dropped.
  3. `audit/0` — assert every row is on a key still in the keyring (and report
     anything not yet on `primary`) before the operator removes the old key.

  ## AAD reconstruction (must mirror the callers)

  The cipher binds the row's canonical tenant tuple as AAD. This module
  rebuilds that tuple from each row's stored columns; the shapes here MUST
  stay identical to `Sanctum.Secrets`, `Sanctum.OAuth`, and `Sanctum.Webhook`
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

  Returns `{:ok, %{secrets: summary, oauth_credentials: summary, webhooks:
  summary, dry_run: bool}}` or `{:error, {table, reason, sample_id}}` (the run
  aborted fail-closed; rerun after fixing the cause — already-rotated rows are
  skipped).
  """
  @spec reencrypt_all(keyword()) :: {:ok, map()} | {:error, {atom(), term(), term()}}
  def reencrypt_all(opts \\ []) do
    ensure_started()
    dry = Keyword.get(opts, :dry_run, false)

    with {:ok, s} <- rotate_table(:secrets, opts),
         {:ok, o} <- rotate_table(:oauth_credentials, opts),
         {:ok, w} <- rotate_table(:webhooks, opts) do
      result = %{secrets: s, oauth_credentials: o, webhooks: w, dry_run: dry}
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
          {:secrets, :encrypted_value},
          {:oauth_credentials, :encrypted_data},
          {:webhooks, :secret_encrypted}
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

  defp rotate_row(:secrets, row, opts) do
    aad = Sanctum.CipherAAD.secret(row.scope, row.org_id, row.project_id, row.name)

    rotate_columns(:secrets, row.id, [{:encrypted_value, row.ct, aad}], opts, fn ->
      Arca.Cache.invalidate({:secret, {row.name, row.scope, row.org_id, row.project_id}})
    end)
  end

  defp rotate_row(:oauth_credentials, %{component_ref: ""} = row, _opts) do
    # Token bundles are always written with a non-empty `component_ref`. An
    # empty ref is an unexpected legacy shape — surface it, never silently
    # skip (it would become undecryptable once the old key is retired).
    {:error, {:unexpected_empty_component_ref, row.id}}
  end

  defp rotate_row(:oauth_credentials, row, opts) do
    aad =
      Sanctum.CipherAAD.oauth_token(row.component_ref, row.provider, row.org_id, row.project_id)

    rotate_columns(:oauth_credentials, row.id, [{:encrypted_data, row.ct, aad}], opts, fn ->
      Arca.Cache.invalidate(
        {:oauth_token, {row.component_ref, row.provider, row.org_id, row.project_id}}
      )

      Arca.Cache.invalidate(
        {:oauth_token_dec, {row.component_ref, row.provider, row.org_id, row.project_id}}
      )
    end)
  end

  defp rotate_row(:webhooks, row, opts) do
    aad = Sanctum.CipherAAD.webhook_secret(row.scope_type, row.org_id, row.project_id, row.name)

    cols =
      [{:secret_encrypted, row.sec, aad}] ++
        if is_binary(row.prev), do: [{:previous_secret_encrypted, row.prev, aad}], else: []

    rotate_columns(:webhooks, row.id, cols, opts, fn -> :ok end)
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

  # planned: %{col => new_ct} for columns that needed rotation.
  defp classify(cols, primary) do
    Enum.reduce_while(cols, {:skip}, fn {col, ct, aad}, state ->
      case Cipher.label(ct) do
        {:ok, ^primary} ->
          {:cont, state}

        {:ok, _other} ->
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
          {:halt, {:error, {:not_a_v2_envelope, col}}}
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

  defp fetch_page(:secrets, cursor, batch) do
    base(cursor, batch, Arca.Schemas.Secret)
    |> select([r], %{
      id: r.id,
      name: r.name,
      scope: r.scope,
      org_id: r.org_id,
      project_id: r.project_id,
      ct: r.encrypted_value
    })
    |> Arca.Repo.all()
  end

  defp fetch_page(:oauth_credentials, cursor, batch) do
    base(cursor, batch, Arca.Schemas.OauthCredential)
    |> select([r], %{
      id: r.id,
      component_ref: r.component_ref,
      provider: r.provider,
      org_id: r.org_id,
      project_id: r.project_id,
      ct: r.encrypted_data
    })
    |> Arca.Repo.all()
  end

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

  defp base(nil, batch, schema) do
    from(r in schema, order_by: [asc: r.id], limit: ^batch)
  end

  defp base(cursor, batch, schema) do
    from(r in schema, where: r.id > ^cursor, order_by: [asc: r.id], limit: ^batch)
  end

  defp schema_for(:secrets), do: Arca.Schemas.Secret
  defp schema_for(:oauth_credentials), do: Arca.Schemas.OauthCredential
  defp schema_for(:webhooks), do: Arca.Schemas.Webhook

  defp audit_table(table, col, primary) do
    rows =
      from(r in schema_for(table), select: field(r, ^col))
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
