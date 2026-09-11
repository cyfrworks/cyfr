# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.TenantTables do
  @moduledoc """
  The closed roster of athanor-scoped tables, and the one verb that
  deletes an athanor's rows from every one of them.

  ## Scope

  Purges athanor-owned database rows, including credentials, execution
  records, messages, and logs. Blob deletion is handled separately by
  `Sanctum.Tenancy.Athanors.purge_storage/1`.

  ## Order

  `@roster` is ordered children-first, so the deletes hold whether or not
  the backend enforces `ON DELETE CASCADE` (SQLite only does with
  `PRAGMA foreign_keys=ON`). `consent_vault_refs` before `consents` and
  `vault_entries`; `consents` before `profiles` (its `profile_id` is a
  composite FK); `messages` before `conversations`; `webhook_deliveries`
  before `webhooks`.

  ## What this does NOT promise

  Row deletion does not guarantee erasure of bytes from database files
  or backups. Physical reclamation depends on the database backend and
  the operator’s storage lifecycle.
  """

  import Ecto.Query

  # Every table carrying `athanor_id`, children first. `verify_roster!/0`
  # checks this against the live schema, so a new athanor-scoped table
  # fails the boot rather than surviving erasure silently.
  @roster [
    "execution_events",
    "approvals",
    "turn_steps",
    "turns",
    "agents",
    "agent_revisions",
    "execution_payloads",
    "consent_vault_refs",
    "consents",
    "profiles",
    "vault_entries",
    "consent_proofs",
    "tool_grants",
    "topic_subscriptions",
    "messages",
    "conversations",
    "webhooks",
    "sessions",
    "api_keys",
    "components",
    "executions",
    "mcp_logs",
    "policy_logs",
    "oauth_provider_credentials",
    "mcp_servers",
    "cron_schedules",
    "build_records",
    "memberships"
  ]

  # Reached through a parent instead of by `athanor_id`, deleted first.
  @by_parent [{"webhook_deliveries", :webhook_id, "webhooks"}]

  # config:compile-runtime-ok — must match what `Arca.Repo` compiled
  # against, exactly as `Arca.Repo.Errors` does.
  #
  # Which tables carry the column, asked in the dialect this build speaks.
  # Selected at COMPILE time because the adapter is: `Arca.Repo` binds it
  # with `Application.compile_env/3`, so a runtime `case` on
  # `__adapter__/0` is a branch the compiler proves dead.
  @athanor_column_sql (case Application.compile_env(:cyfr, :repo_adapter, Ecto.Adapters.SQLite3) do
                         Ecto.Adapters.Postgres ->
                           """
                           SELECT table_name FROM information_schema.columns
                           WHERE column_name = 'athanor_id' AND table_schema = current_schema()
                           """

                         _sqlite ->
                           """
                           SELECT m.name FROM sqlite_master m
                           JOIN pragma_table_info(m.name) p
                           WHERE m.type = 'table' AND p.name = 'athanor_id'
                           """
                       end)

  # Carries no `athanor_id` and is deliberately NOT an athanor's to
  # delete: a registry token belongs to the person and their namespace,
  # keyed `(user_id, registry, namespace_slug)`. It outlives any one
  # athanor, exactly as an API key outlives its creator's membership.
  #
  # `server_meta` is the server's own facts — the keyring fingerprint, the
  # control-plane owner — one row per key and no tenant at all.
  @not_athanor_scoped ["registry_tokens", "server_meta"]

  @doc "The closed roster, children first."
  @spec roster() :: [String.t()]
  def roster, do: @roster

  @doc "Tables reached through a parent rather than by `athanor_id`."
  @spec by_parent() :: [{String.t(), atom(), String.t()}]
  def by_parent, do: @by_parent

  @doc "Tables with no `athanor_id`, listed so the roster check can say why."
  @spec not_athanor_scoped() :: [String.t()]
  def not_athanor_scoped, do: @not_athanor_scoped

  @doc """
  Delete every row this athanor owns, in one transaction.

  Returns `{:ok, %{table => count}}`. The ROWS are all-or-nothing: they go
  in one transaction, because a half-deleted athanor leaves a caller
  believing data is gone that is not.

  The OPERATION is not. `Sanctum.Tenancy.Athanors.destroy/1` reclaims the
  storage tree before calling this — it needs the athanor row to build the
  context, so the order cannot simply be swapped — and if this then fails,
  the blobs are already gone while the rows stand. That is recoverable
  (retry erases more, never less) and it is the honest shape to state,
  rather than a promise of atomicity across two stores that have no shared
  transaction.
  """
  @spec delete_all_for(String.t()) :: {:ok, %{String.t() => non_neg_integer()}} | {:error, term()}
  def delete_all_for(athanor_id) when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TenantTables.delete_all_for", fn ->
      Arca.Repo.transaction(fn ->
        parent_counts =
          Map.new(@by_parent, fn {table, fk, parent} ->
            parent_ids =
              from(p in parent, where: p.athanor_id == ^athanor_id, select: p.id)

            {count, _} =
              from(t in table, where: field(t, ^fk) in subquery(parent_ids))
              |> Arca.Repo.delete_all()

            {table, count}
          end)

        Enum.reduce(@roster, parent_counts, fn table, acc ->
          {count, _} =
            from(t in table, where: t.athanor_id == ^athanor_id)
            |> Arca.Repo.delete_all()

          Map.put(acc, table, count)
        end)
      end)
    end)
  end

  @doc """
  Every table the live schema says carries `athanor_id`.

  Asked of the database rather than derived from the schema modules: the
  athanor-scoped tables are declared in four different places (a
  `schemas/` module for most, an inline `use Ecto.Schema` in
  `Arca.Execution`, `Arca.McpLog`, `Arca.PolicyLog` and
  `Arca.CronSchedule`), so a module scan would answer for the modules it
  happened to find. The column is the fact.
  """
  @spec athanor_scoped_tables() :: [String.t()]
  # arca:unscoped-ok a boot-time schema read over the catalog, not tenant
  # rows — there is no athanor to scope it to.
  #
  # arca:db-raise-ok raising IS the contract. This backs `verify_roster!/1`,
  # whose entire job is to fail a boot rather than let an athanor-scoped
  # table survive an erasure that reported success; answering
  # `{:error, :database_error}` would turn that into a shrug.
  def athanor_scoped_tables do
    %{rows: rows} = Arca.Repo.query!(@athanor_column_sql, [])

    rows |> List.flatten() |> Enum.sort()
  end

  @doc """
  Assert the roster still covers every athanor-scoped table.

  A table that carries `athanor_id` and is not here is one `destroy/1`
  would leave behind — the exact shape of the gap this module closes, and
  invisible until somebody looks. Raises, so it fails a boot rather than
  a backup.
  """
  # `roster` is a parameter so a test can drive BOTH directions against the
  # live schema. Asserting only that the shipped roster returns `:ok` proves
  # today's list matches today's tables and says nothing about whether the
  # check can fail at all.
  @spec verify_roster!([String.t()]) :: :ok
  def verify_roster!(roster \\ @roster) do
    live = athanor_scoped_tables()
    known = Enum.sort(roster ++ @not_athanor_scoped ++ ["athanors"])

    unrostered = live -- known
    # The other direction. A roster entry whose table is gone makes
    # `delete_all_for/1` raise on the next erasure, and nothing else would
    # have said so — the failure this module exists to prevent, arriving
    # from the opposite side.
    stale = roster -- live

    cond do
      unrostered != [] ->
        raise """
        These tables carry `athanor_id` and are not in Arca.TenantTables:

          #{inspect(unrostered)}

        `Sanctum.Tenancy.Athanors.destroy/1` would leave their rows behind,
        so an athanor's data would survive an erasure that reported success.
        Add each to @roster (children first), or to @not_athanor_scoped with
        the reason it is not an athanor's to delete.
        """

      stale != [] ->
        raise """
        These are rostered in Arca.TenantTables but carry no `athanor_id`
        in the live schema:

          #{inspect(stale)}

        `delete_all_for/1` would raise on the next erasure. Drop each from
        @roster, or restore the column.
        """

      true ->
        :ok
    end
  end
end
