defmodule Arca.Repo.Migrations.RekeyCredentialStoreAndIndexes do
  @moduledoc """
  Auth-refactor rekey migration.

  Shipped as part of the Phase A client-side rollout (see auth_refactor.md).
  Intentionally destructive: TRUNCATE `sessions`, TRUNCATE `api_keys`,
  and DELETE `_registry.%` secrets. Runs once at deploy time AFTER all
  Phase A Elixir code is in main, BEFORE traffic cutover.

  This wipes out:

  - `sessions` — `user_id` shape changes to `"<provider>|<iss>|<subject>"`.
  - `api_keys` — `created_by` shape changes (same as sessions) AND the
    stale 3-col unique index `api_keys_name_scope_type_org_id_index` from
    migration `20240303000001` is dropped (migration `20260312000001`
    failed to drop it due to a 2-col signature typo).
  - Rows in `secrets` named `_registry.%` OR `registry_credentials` —
    CredentialStore re-keys from `_registry.{registry}.{user_id}` to
    `_registry.{registry}.{user_id}.{namespace_slug}` and only push-token
    shape is stored post-refactor; legacy Arx tenant creds under
    `registry_credentials` are also wiped.

  A new index `sessions_user_id_index` is created to support
  multi-session listings for a user.

  **Irreversibility note.** The data wipe is not undone by `down`. Running
  `mix ecto.rollback` will recreate the stale `api_keys` index but won't
  restore rows. This is acceptable because Phase A's deployment runbook
  includes a `pg_dump -Fc` snapshot before running this migration.
  """

  use Ecto.Migration

  def up do
    # 1. New index for multi-session-per-user listings. Uses IF NOT EXISTS
    #    because SQLite may replay portions on partial failure.
    execute("CREATE INDEX IF NOT EXISTS sessions_user_id_index ON sessions (user_id)")

    # 2. Wipe sessions — user_id shape changes to pipe-delimited.
    #    Try TRUNCATE first; fall back to DELETE for SQLite (which doesn't
    #    support TRUNCATE). Both reach the same end-state for our tables.
    execute("DELETE FROM sessions")

    # 3. Wipe api_keys — created_by shape changes; the 4-col unique index
    #    becomes authoritative in place of the stale 3-col one.
    execute("DELETE FROM api_keys")

    # 4. Drop the stale 3-col unique index the 2026-03 migration intended
    #    to drop but typoed. Safe-to-rerun via IF EXISTS.
    execute("DROP INDEX IF EXISTS api_keys_name_scope_type_org_id_index")

    # 5. Rekey CredentialStore: drop every `_registry.*` secret and the
    #    legacy Arx tenant `registry_credentials` entry. Users re-login
    #    via device-flow (or web OAuth) post-deploy to repopulate via
    #    `Compendium.Registry.Client.probe_identity/3`.
    execute("DELETE FROM secrets WHERE name LIKE '_registry.%'")
    execute("DELETE FROM secrets WHERE name = 'registry_credentials'")
  end

  def down do
    # Recreate the stale index we dropped (for rollback symmetry only).
    # Data wipe is not reversed; runbook relies on `pg_dump -Fc` snapshots.
    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS api_keys_name_scope_type_org_id_index
    ON api_keys (name, scope_type, org_id)
    """)

    execute("DROP INDEX IF EXISTS sessions_user_id_index")
  end
end
