# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.TenantTables do
  @moduledoc """
  The closed roster of athanor-scoped tables, held to the live schema at
  every boot (`verify_roster!/1`), so every table that carries
  `athanor_id` is named here or in `not_athanor_scoped/0` with its reason.
  Nothing in the product deletes an athanor; a test erases the rows it
  made through this roster (`Arca.Test.TenantTables.delete_all_for/1`).

  ## Order

  `@roster` is ordered children-first, so a delete in its order holds whether or not
  the backend enforces `ON DELETE CASCADE` (SQLite only does with
  `PRAGMA foreign_keys=ON`). `consent_vault_refs` and `vault_defaults`
  before `consents` and `vault_entries`; `consents` before `profiles` (its
  `profile_id` is a composite FK); `share_usage` before `shares` and
  `shares` before `vault_entries`; `messages` before `threads`;
  `webhook_deliveries` before `webhooks`.

  A file offer is the sender's athanor's row (`file_offers`), so an offer
  not yet accepted dies with it; an accepted transfer is the recipient's
  (`file_receipts`), and lives and completes there whatever happens to
  the sender.
  """

  # Every table carrying `athanor_id`, children first. `verify_roster!/1`
  # checks this against the live schema, so a new athanor-scoped table
  # fails the boot until it is named. Two of them may hold rows with no
  # athanor — `sessions` and `decision_logs`: a null-tenant decision is
  # the host's, purged under its own retention.
  @roster [
    "execution_events",
    "rate_windows",
    "budget_charges",
    "budget_reservations",
    "storage_write_intents",
    "object_generations",
    "object_revisions",
    "execution_attempts",
    "approvals",
    "turn_steps",
    "turns",
    "agents",
    "agent_revisions",
    "execution_payloads",
    "consent_vault_refs",
    "vault_defaults",
    "consents",
    "profiles",
    "share_usage",
    "shares",
    "vault_entries",
    "consent_proofs",
    "tool_grants",
    "messages",
    "threads",
    "webhooks",
    "sessions",
    "api_keys",
    "frame_credentials",
    "device_certificates",
    "pending_confirmations",
    "pairing_invitations",
    "device_pin_evaluators",
    "paired_clients",
    "storage_projection_changes",
    "storage_projection_roots",
    "fenced_documents",
    "fenced_document_floors",
    "storage_staging",
    "storage_commits",
    "storage_units",
    "components",
    "executions",
    "mcp_logs",
    "policy_logs",
    "decision_logs",
    "retention_settings",
    "oauth_provider_credentials",
    "file_offers",
    "file_receipts",
    "mcp_servers",
    "consumer_receipts",
    "outbox_records",
    "schedule_occurrences",
    "cron_schedules",
    "build_records",
    "provisioning_claims"
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
  @athanor_column_sql (case Application.compile_env(:arca, :repo_adapter, Ecto.Adapters.SQLite3) do
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
  # athanor.
  #
  # `server_meta` is the server's own facts — the schema and keyring
  # fingerprints — one row per key and no tenant at all.
  #
  # `cell_leases` and `job_claims` are the cell's: which node holds a member
  # slot, and who is running one of the cell's singleton jobs. A cell has no
  # athanor, and several job kinds have no athanor at all; a claim naming an
  # athanor's credential in its `key` is a mutual-exclusion token and grants
  # no reach into that athanor, so it is not the athanor's row to delete.
  #
  # `platform_settings` and `settings_pins` are the cell's settings and
  # each member's environment pins of them: node facts every member reads
  # alike, which no athanor owns.
  #
  # `person_identities`, `identity_attempts`, `identity_log_entries`,
  # `directory_heads` and `carry_actions` are a person's identity and
  # their carries, which are not an athanor's to delete: a person's keys
  # and identifier outlive every athanor they sit in, a directory orders
  # identifiers, and a carry moves a person between homes.
  #
  # `passkeys` are a person's own credentials at this home, revoked with
  # the person (`Arca.SecurityTransitions`), never with an athanor.
  #
  # `company_authorizations` and `company_login_attempts` are a person's
  # company sign-in and the sign-ins they have in flight: the person's,
  # deleted with their `users` row, never with an athanor.
  #
  # `restore_people` is a person's period after a declared restore. Its
  # owner is the person: each row references `users` and is deleted with
  # it, never with an athanor, and a person's denial leaves it.
  #
  # `device_certifications` are what this home certified for its people's
  # devices at other homes: the athanor each names is the other home's,
  # and the row goes with the person.
  #
  # `installation_claims` are the node's claims by a restore, and
  # `request_rate_windows` the node's pre-authentication limits: no
  # session, and so no athanor, stands behind either.
  #
  # `shared_threads`, `shared_thread_members` and `shared_messages` are a
  # place several people talk in, its people and what they say: no athanor
  # holds a shared thread.
  #
  # `invitations` are invitations to this CYFR: the instance's admission,
  # naming at most a shared thread, which no athanor holds either.
  @not_athanor_scoped [
    "registry_tokens",
    "server_meta",
    "cell_leases",
    "job_claims",
    "platform_settings",
    "settings_pins",
    "person_identities",
    "identity_attempts",
    "identity_log_entries",
    "directory_heads",
    "carry_actions",
    "passkeys",
    "company_authorizations",
    "company_login_attempts",
    "restore_people",
    "device_certifications",
    "installation_claims",
    "request_rate_windows",
    "shared_threads",
    "shared_thread_members",
    "shared_messages",
    "invitations"
  ]

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
  Every table the live schema says carries `athanor_id`.

  Asked of the database rather than derived from the schema modules: a
  module scan would answer for the modules it happened to find, and a
  table can carry the column with no schema at all. The column is the
  fact.
  """
  @spec athanor_scoped_tables() :: [String.t()]
  # arca:unscoped-ok a boot-time schema read over the catalog, not tenant
  # rows — there is no athanor to scope it to.
  #
  # arca:db-raise-ok raising IS the contract. This backs `verify_roster!/1`,
  # whose entire job is to fail a boot rather than let an athanor-scoped
  # table go unnamed; answering
  # `{:error, :database_error}` would turn that into a shrug.
  def athanor_scoped_tables do
    %{rows: rows} = Arca.Repo.query!(@athanor_column_sql, [])

    rows |> List.flatten() |> Enum.sort()
  end

  @doc """
  Assert the roster still covers every athanor-scoped table.

  A table that carries `athanor_id` and is not here is one no reader of
  the roster knows is an athanor's, invisible until somebody looks.
  Raises, so it fails a boot.
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
    # The other direction: a roster entry whose table is gone names a
    # table no statement can reach, and nothing else would have said so.
    stale = roster -- live

    cond do
      unrostered != [] ->
        raise """
        These tables carry `athanor_id` and are not in Arca.TenantTables:

          #{inspect(unrostered)}

        Add each to @roster (children first), or to @not_athanor_scoped with
        the reason it is not an athanor's to delete.
        """

      stale != [] ->
        raise """
        These are rostered in Arca.TenantTables but carry no `athanor_id`
        in the live schema:

          #{inspect(stale)}

        Drop each from @roster, or restore the column.
        """

      true ->
        :ok
    end
  end
end
