# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.Baseline do
  @moduledoc """
  The schema, as one migration.

  This replaces 81 migrations that recorded how the schema was arrived at:
  nine tables created and later dropped, thirteen backfills that only ever
  meant anything to an installation upgrading from a version that no longer
  exists, and four adapter-conditional type corrections for columns that are
  simply declared correctly here. None of that history is reachable from a
  fresh install, and there is no upgrade path across this baseline.

  There is deliberately no `down/0`. A baseline's inverse is an empty
  database, which `mix ecto.drop` already expresses.
  """

  use Ecto.Migration

  def up do
    tenancy()
    identity()
    components()
    executions_and_logs()
    vault_and_consent()
    registrations()
    seed_default_workspace()
  end

  # ==========================================================================
  # Tenancy
  # ==========================================================================

  defp tenancy do
    create table(:orgs, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:orgs, [:slug])

    create table(:projects, primary_key: false) do
      add :id, :string, primary_key: true
      add :org_id, references(:orgs, type: :string, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      add :settings, :text
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:projects, [:org_id, :slug])

    # Presence-only assignments: a row means "user X is admin of scope S".
    # No roles, no invite ceremony.
    create table(:memberships, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, :string, null: false
      add :scope, :string, null: false, default: "project"
      add :org_id, references(:orgs, type: :string, on_delete: :delete_all)
      add :project_id, references(:projects, type: :string, on_delete: :delete_all)
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:memberships, [:user_id])

    # Raw SQL because the uniqueness has to treat NULL org/project as a value
    # — a platform-scope assignment carries neither, and two of those for one
    # user are the same assignment. COALESCE in an index expression is not
    # something `unique_index/3` can express.
    execute """
    CREATE UNIQUE INDEX memberships_assignment_index
    ON memberships (user_id, scope, COALESCE(org_id, ''), COALESCE(project_id, ''))
    """
  end

  # ==========================================================================
  # Identity: sessions and API keys
  # ==========================================================================

  defp identity do
    create table(:sessions, primary_key: false) do
      add :id, :string, primary_key: true
      add :token_hash, :binary, null: false
      add :token_prefix, :string
      add :user_id, :string, null: false
      add :email, :string
      add :provider, :string, null: false
      add :permissions, :text, null: false, default: "[]"
      add :expires_at, :utc_datetime_usec, null: false
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"
      add :scope, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:sessions, [:token_hash])
    create index(:sessions, [:user_id])

    create table(:api_keys, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :key_hash, :binary, null: false
      add :key_prefix, :string, null: false
      add :type, :string, null: false
      add :scope, :text, null: false, default: "[]"
      add :rate_limit, :string
      add :ip_allowlist, :text
      add :revoked, :boolean, null: false, default: false
      add :created_by, :string
      add :rotated_at, :utc_datetime_usec
      add :scope_type, :string, null: false, default: "personal"
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"
      add :capability, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_keys, [:key_hash])

    # Partial: a revoked key's name is immediately reusable.
    create unique_index(:api_keys, [:name, :scope_type, :org_id, :project_id],
             where: "NOT revoked",
             name: :api_keys_active_name_index
           )

    create table(:registry_tokens, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, :string, null: false
      add :registry, :string, null: false
      add :namespace_slug, :string, null: false
      add :credential_ciphertext, :binary, null: false
      add :issued_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:registry_tokens, [:user_id, :registry, :namespace_slug])
    create index(:registry_tokens, [:user_id, :registry])
  end

  # ==========================================================================
  # Components
  # ==========================================================================

  defp components do
    create table(:components, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :version, :string, null: false
      add :component_type, :string, null: false
      # `:text` from the start: these outgrew varchar(255) once already, and
      # the correction had to be a Postgres-only migration.
      add :description, :text
      add :tags, :text
      add :category, :string
      add :license, :string
      add :digest, :string, null: false
      add :size, :integer
      add :exports, :text
      add :publisher_id, :string
      add :org_id, :string
      add :publisher, :string, null: false, default: "local"
      add :source, :string, null: false, default: "published"
      add :manifest, :text
      add :signature_verified, :boolean, default: false
      add :signer_identity, :string
      add :signer_issuer, :string
      add :project_id, :string, null: false, default: "default"
      add :release_digest, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:components, [:name])
    create index(:components, [:component_type])
    create index(:components, [:publisher])
    create index(:components, [:source])
    create index(:components, [:digest])

    create unique_index(
             :components,
             [:publisher, :name, :version, :component_type, :org_id, :project_id]
           )

    create table(:component_dependencies, primary_key: false) do
      add :id, :string, primary_key: true

      add :component_id,
          references(:components, type: :string, on_delete: :delete_all),
          null: false

      add :dependency_ref, :string, null: false
      add :dep_type, :string, null: false
      add :dep_namespace, :string, null: false
      add :dep_name, :string, null: false
      add :dep_version, :string, null: false
      add :optional, :boolean, null: false, default: false
      add :reason, :string
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:component_dependencies, [:component_id])
    create index(:component_dependencies, [:dep_name])
    create unique_index(:component_dependencies, [:component_id, :dependency_ref])
    create index(:component_dependencies, [:org_id, :project_id])
  end

  # ==========================================================================
  # Executions and audit logs
  # ==========================================================================

  defp executions_and_logs do
    create table(:executions, primary_key: false) do
      add :id, :string, primary_key: true
      add :reference, :string, null: false
      add :input_hash, :string
      add :user_id, :string, null: false
      add :component_type, :string, default: "reagent"
      add :component_digest, :string
      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
      add :duration_ms, :integer
      add :status, :string, null: false, default: "running"
      add :error_message, :text
      add :request_id, :string
      add :input, :text
      add :output, :text
      add :wasi_trace, :text
      add :host_policy, :text
      add :parent_execution_id, :string
      add :resolver_digest, :string
      add :org_id, :string
      add :project_id, :string
      add :activation_digest, :string
      add :activation_graph, :text
      add :root_execution_id, :string
    end

    create index(:executions, [:started_at])
    create index(:executions, [:user_id])
    create index(:executions, [:status])
    create index(:executions, [:request_id])
    create index(:executions, [:parent_execution_id])
    create index(:executions, [:root_execution_id])
    create index(:executions, [:org_id])
    create index(:executions, [:project_id])
    create index(:executions, [:org_id, :project_id])
    create index(:executions, [:org_id, :project_id, :user_id, :started_at])
    create index(:executions, [:org_id, :project_id, :status, :started_at])

    create table(:mcp_logs, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, :string
      add :timestamp, :utc_datetime_usec, null: false
      add :tool, :string
      add :action, :string
      add :method, :string
      add :status, :string, null: false, default: "pending"
      add :duration_ms, :integer
      add :routed_to, :string
      add :error_code, :integer
      add :input, :text
      add :output, :text
      add :error, :text
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"
      # The ingress request a call belongs to; a chain shares one.
      add :request_id, :string
    end

    create index(:mcp_logs, [:user_id])
    create index(:mcp_logs, [:timestamp])
    create index(:mcp_logs, [:status])
    create index(:mcp_logs, [:request_id])
    create index(:mcp_logs, [:org_id, :project_id])
    create index(:mcp_logs, [:org_id, :project_id, :timestamp])

    create table(:policy_logs, primary_key: false) do
      add :id, :string, primary_key: true
      add :request_id, :string
      add :execution_id, :string
      add :user_id, :string, null: false
      add :timestamp, :utc_datetime_usec, null: false
      add :event_type, :string, null: false
      add :component_ref, :string
      add :component_type, :string
      add :decision, :string
      add :host_policy_snapshot, :text
      add :decision_reason, :text
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"
      add :consent_id, :string
      add :activation_digest, :string
      add :dep_ref, :string
      add :need, :string
      add :cursor_state, :string
      add :chain, :text
      add :value_source, :string
    end

    create index(:policy_logs, [:request_id])
    create index(:policy_logs, [:execution_id])
    create index(:policy_logs, [:user_id])
    create index(:policy_logs, [:timestamp])
    create index(:policy_logs, [:org_id, :project_id])
    create index(:policy_logs, [:consent_id])
  end

  # ==========================================================================
  # Vault and consent
  # ==========================================================================

  defp vault_and_consent do
    # One row per external account. Credentials are shared, never copied:
    # several profiles reference one entry through consent edges. The sealed
    # payload arrives encrypted — Arca stores bytes.
    create table(:vault_entries, primary_key: false) do
      add :id, :string, primary_key: true
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"
      add :name, :string, null: false
      add :provider_hint, :string, null: false, default: ""
      add :kind, :string, null: false
      add :system, :boolean, null: false, default: false
      add :provenance, :string, null: false, default: "user"
      add :field_names, :text, null: false, default: "[]"
      add :binding_digest, :string
      add :oauth_endpoints, :text
      add :oauth_scopes, :text
      add :status, :string, null: false, default: "active"
      add :payload_rev, :integer, null: false, default: 0
      add :sealed_payload, :binary
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # The parent side of the two-column composite foreign keys below: a
    # 3+-column composite FK silently truncates on SQLite, so referencing
    # tables carry (org_id, <fk>) pairs and this index must exist first.
    create unique_index(:vault_entries, [:org_id, :id])

    create unique_index(:vault_entries, [:name, :project_id, :org_id],
             where: "status != 'tombstoned'",
             name: :vault_entries_active_name_index
           )

    create index(:vault_entries, [:org_id, :project_id])

    create table(:profiles, primary_key: false) do
      add :id, :string, primary_key: true
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"
      add :source_ref, :string, null: false
      add :kind, :string, null: false, default: "owner"
      add :label, :string, null: false, default: "default"
      add :status, :string, null: false, default: "active"
      add :head_consent_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:profiles, [:org_id, :id])

    create unique_index(:profiles, [:source_ref, :label, :kind, :project_id, :org_id],
             where: "status != 'revoked'",
             name: :profiles_active_identity_index
           )

    create index(:profiles, [:source_ref, :project_id, :org_id])

    # Insert-only: a revision that exists but is not the head is history.
    create table(:consents, primary_key: false) do
      add :id, :string, primary_key: true
      add :org_id, :string, null: false, default: ""
      add :profile_id,
          references(:profiles, column: :id, type: :string, with: [org_id: :org_id]),
          null: false

      add :revision, :integer, null: false
      add :scope, :string, null: false
      add :pinned_version, :string, null: false, default: ""
      add :invoke_mode, :string, null: false, default: "open_inert"
      add :shape_digest, :string, null: false
      add :commit_digest, :string, null: false
      add :resolved_policy, :binary, null: false
      add :activation, :binary, null: false
      add :granted_by, :string, null: false
      add :granted_via, :string, null: false
      add :granted_at, :utc_datetime_usec, null: false
      add :supersedes_id, :string
    end

    create index(:consents, [:org_id, :profile_id])
    create unique_index(:consents, [:profile_id, :revision])

    create table(:consent_vault_refs, primary_key: false) do
      add :consent_id, references(:consents, column: :id, type: :string), null: false
      add :org_id, :string, null: false, default: ""

      add :vault_entry_id,
          references(:vault_entries, column: :id, type: :string, with: [org_id: :org_id]),
          null: false

      add :binding_digest, :string, null: false
    end

    create unique_index(:consent_vault_refs, [:consent_id, :vault_entry_id])
    create index(:consent_vault_refs, [:vault_entry_id, :org_id])

    # Single-use, delete-on-read. No foreign keys by design: a proof outlives
    # the plan it came from and must not be cascaded away.
    create table(:consent_proofs, primary_key: false) do
      add :token_hash, :string, primary_key: true
      add :kind, :string, null: false
      add :digest, :string, null: false
      add :bindings, :text, null: false, default: "{}"
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:consent_proofs, [:expires_at])

    create table(:oauth_provider_credentials, primary_key: false) do
      add :id, :string, primary_key: true
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"
      add :provider, :string, null: false
      add :payload_ciphertext, :binary, null: false
      add :created_by, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:oauth_provider_credentials, [:provider, :org_id, :project_id])
  end

  # ==========================================================================
  # Standing invocation channels
  # ==========================================================================

  defp registrations do
    create table(:mcp_servers, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :url, :string, null: false
      add :config_json, :text, default: "{}"
      add :enabled, :boolean, default: true
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mcp_servers, [:name, :org_id, :project_id])
    create index(:mcp_servers, [:org_id, :project_id])

    # `profile_id` is nullable in the column and required by the code: a
    # webhook fires under its bound profile's consent or refuses.
    create table(:webhooks, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :target_ref, :string, null: false
      add :secret_encrypted, :binary, null: false
      add :signature_header, :string, null: false, default: "x-cyfr-signature"
      add :input_template, :text, null: false, default: "{}"
      add :description, :text
      add :enabled, :boolean, null: false, default: true
      add :rate_limit, :string
      add :created_by, :string
      add :rotated_at, :utc_datetime_usec
      add :scope_type, :string, null: false, default: "project"
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"
      add :timestamp_header, :string
      add :idempotency_key_header, :string
      add :previous_secret_encrypted, :binary
      add :previous_secret_expires_at, :utc_datetime_usec
      add :profile_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:webhooks, [:slug])
    create unique_index(:webhooks, [:name, :scope_type, :org_id, :project_id])

    create table(:webhook_deliveries, primary_key: false) do
      add :id, :string, primary_key: true

      add :webhook_id,
          references(:webhooks, type: :string, on_delete: :delete_all),
          null: false

      add :idempotency_key, :string, null: false
      add :first_seen_at, :utc_datetime_usec, null: false
    end

    create unique_index(:webhook_deliveries, [:webhook_id, :idempotency_key])
    create index(:webhook_deliveries, [:first_seen_at])

    create table(:cron_schedules, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, :string, null: false
      add :name, :string, null: false
      add :cron_expression, :string, null: false
      add :reference, :string, null: false
      add :input, :text
      add :metadata, :text
      add :status, :string, null: false, default: "active"
      add :last_run_at, :utc_datetime_usec
      add :next_run_at, :utc_datetime_usec
      add :last_execution_id, :string
      add :run_count, :integer, null: false, default: 0
      add :error_count, :integer, null: false, default: 0
      add :resolved_reference, :string
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"
      add :profile_id, :string
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:cron_schedules, [:user_id])
    create index(:cron_schedules, [:status])
    create index(:cron_schedules, [:next_run_at])
    create index(:cron_schedules, [:org_id, :project_id])

    create unique_index(:cron_schedules, [:user_id, :name],
             where: "status != 'deleted'",
             name: :cron_schedules_user_name_active
           )
  end

  # ==========================================================================
  # The out-of-the-box workspace
  # ==========================================================================

  # Every context resolves to a concrete (org, project), so the pair the
  # seeded install runs as has to exist before the first request. `:nothing`
  # on conflict because several nodes may boot at once.
  defp seed_default_workspace do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    execute(fn ->
      repo().insert_all(
        "orgs",
        [%{id: "local", name: "Local", slug: "local", created_at: now, updated_at: now}],
        on_conflict: :nothing,
        conflict_target: :id
      )

      repo().insert_all(
        "projects",
        [
          %{
            id: "default",
            org_id: "local",
            name: "Default",
            slug: "default",
            created_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: :id
      )
    end)
  end
end
