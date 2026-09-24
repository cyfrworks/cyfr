# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.Baseline do
  @moduledoc """
  The schema, as one migration.

  Every tenant-owned row carries an `athanor_id` — the athanor (a person's or
  a group's furnace) that owns it. The column is `NOT NULL` with no default:
  a row that forgets its athanor must fail, never default into somebody's.
  It carries no foreign key TO `athanors` on purpose — an athanor is
  archived, never deleted, so nothing needs the constraint and every fixture
  is spared a parent row. Several tables do name it inside a COMPOSITE key,
  which is a different thing: a child references its parent by
  `(id, athanor_id)`, so nothing can point across estates. Those constrain
  the pair, never the athanor itself. A 3+-column composite foreign key
  silently truncates on SQLite, so every composite is a two-column pair and
  its parent carries a unique `(id, athanor_id)` index created first.

  The two nullable `athanor_id` columns are `memberships` (a platform
  assignment has no athanor) and `sessions` (a session exists before its
  athanor is resolved). `server_meta`, `registry_tokens`,
  `external_identities`, `cell_leases` and `job_claims` are not
  athanor-scoped: the first three are the server's own facts and the last
  two the cell's, and a cell has no estate.

  This file is the schema's single source: a change edits it, and
  `Arca.SchemaFingerprint` refuses a database built from a different
  version of it. There is deliberately no `down/0` and no upgrade path; a
  baseline's inverse is an empty database, which `mix ecto.drop` expresses.
  """

  use Ecto.Migration

  def up do
    tenancy()
    provisioning()
    identity()
    server()
    cell()
    components()
    storage_units()
    storage_projections()
    agents()
    executions()
    logs()
    retention()
    vault_and_consent()
    registrations()
    schedules()
    threads()
    turns()
    record_fingerprint()
  end

  # ==========================================================================
  # Tenancy
  # ==========================================================================

  defp tenancy do
    sqlite? = repo().__adapter__() == Ecto.Adapters.SQLite3

    # The standing counters. A deny/allow or archive/reopen that changes a
    # row's standing raises its counter by one in the same transaction
    # (`Arca.SecurityTransitions`); nothing else writes it. A credential is
    # issued only against the counters its context read, so a context read
    # before a retirement cannot issue after a restore. Positive, starting
    # at 1; spelled once per adapter for the same reason as the MCP
    # transport check below.
    athanor_generation = %{
      name: "athanors_security_generation_positive",
      expr: "security_generation > 0"
    }

    user_generation = %{
      name: "users_security_generation_positive",
      expr: "security_generation > 0"
    }

    create table(:athanors, primary_key: false) do
      add :id, :string, primary_key: true
      add :kind, :string, null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      add :owner_user_id, :string
      add :status, :string, null: false, default: "active"
      add :archived_at, :utc_datetime_usec
      add :created_by, :string, null: false
      add :settings, :text
      add :provisioned_at, :utc_datetime_usec
      # The last automatic fill that failed: when, and `{"step", "detail"}`
      # as JSON. Written by the server alone and cleared by a completed fill.
      add :provisioning_failed_at, :utc_datetime_usec
      add :provisioning_failure, :text
      # open | frozen: a two-person athanor's members are fixed at creation.
      add :roster, :string, null: false, default: "open"
      # SHA-256 over the JSON-encoded sorted member ids of a frozen pair.
      add :pair_key, :string

      add :security_generation, :bigint,
        null: false,
        default: 1,
        check: if(sqlite?, do: athanor_generation)

      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    unless sqlite? do
      create constraint(:athanors, athanor_generation.name, check: athanor_generation.expr)
    end

    create unique_index(:athanors, [:kind, :slug])

    # One personal athanor per person, and one active pair per key. Default
    # index names on purpose: SQLite reports a violation by column, and
    # ecto_sqlite3 derives the constraint name from it, so only the derived
    # name matches the changeset on both adapters.
    create unique_index(:athanors, [:owner_user_id], where: "kind = 'person'")

    create unique_index(:athanors, [:pair_key],
             where: "pair_key IS NOT NULL AND status = 'active'"
           )

    create index(:athanors, [:status])

    # The people this server knows: one row per person, keyed by a minted
    # `usr_…` id. How an identity provider names them is an
    # `external_identities` row. Log tables keep writing user_id without a
    # foreign key here — synthetic principals are not people. `email` is not
    # unique.
    create table(:users, primary_key: false) do
      add :id, :string, primary_key: true
      add :email, :string
      # Tri-state on purpose: true when the provider proved the address,
      # false when it said the opposite, NULL when it said nothing.
      add :email_verified, :boolean
      add :provider, :string, null: false
      add :display_name, :string
      # The cyfr.run publisher namespace, once linked. Not identity.
      add :namespace, :string
      add :personal_athanor_id, :string
      add :status, :string, null: false, default: "active"
      add :prefs, :text
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      add :denied_at, :utc_datetime_usec

      add :security_generation, :bigint,
        null: false,
        default: 1,
        check: if(sqlite?, do: user_generation)

      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    unless sqlite? do
      create constraint(:users, user_generation.name, check: user_generation.expr)
    end

    create index(:users, [:email])
    create index(:users, [:status])
    create unique_index(:users, [:namespace], where: "namespace IS NOT NULL")

    create unique_index(:users, [:personal_athanor_id], where: "personal_athanor_id IS NOT NULL")

    # How an identity provider names a person, keyed by the IdP composite
    # `<provider>|<issuer>|<subject>`. One person may be named by several.
    create table(:external_identities, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :provider, :string, null: false
      add :issuer, :string, null: false
      add :subject, :string, null: false
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
    end

    create unique_index(:external_identities, [:key])
    create index(:external_identities, [:user_id])

    # The door: who may sign in to this server. Entries name an email, an
    # IdP subject, or the wildcard `*`; a deny wins over everything.
    # `requested` rows are allow entries a member asked for by inviting an
    # email the door does not know — they take effect when a platform admin
    # resolves them.
    create table(:server_allowlist, primary_key: false) do
      add :id, :string, primary_key: true
      add :kind, :string, null: false
      add :value, :string, null: false
      add :effect, :string, null: false, default: "allow"
      add :status, :string, null: false, default: "allowed"
      add :requested_by, :string
      add :added_by, :string
      add :note, :text
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:server_allowlist, [:kind, :value])
    create index(:server_allowlist, [:status])

    # Presence-only assignments: a row means "user X is a member of athanor A"
    # (or, with no athanor, a platform admin). No roles. An `invited` row is
    # keyed by email before the person has signed in and carries no user_id;
    # it activates, atomically, on their first admitted sign-in.
    create table(:memberships, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, :string
      add :email, :string
      add :scope, :string, null: false, default: "athanor"
      add :status, :string, null: false, default: "active"
      add :added_by, :string
      add :athanor_id, references(:athanors, type: :string, on_delete: :delete_all)
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:memberships, [:user_id])
    create index(:memberships, [:email])
    create index(:memberships, [:athanor_id])

    # Raw SQL because the uniqueness has to treat a NULL as a value — a
    # platform assignment carries no athanor, an invited row no user, an
    # active row no email — and two rows agreeing on all four are the same
    # assignment. COALESCE in an index expression is not something
    # `unique_index/3` can express.
    execute """
    CREATE UNIQUE INDEX memberships_assignment_index
    ON memberships (scope, COALESCE(athanor_id, ''), COALESCE(user_id, ''), COALESCE(email, ''))
    """
  end

  # ==========================================================================
  # Provisioning claims
  # ==========================================================================

  # Who is filling an estate: one row per athanor, taken and settled by
  # compare-and-set on `(owner, fence)`, so a stale owner — a boot that
  # lost its lease mid-fill — cannot mark readiness, overwrite a
  # successor's failure, mint consent or replace the agent index. Every
  # entry point that fills or heals an estate (`Sanctum.Provisioning`)
  # takes the same row; the lease is what a successor waits out.
  defp provisioning do
    create table(:provisioning_claims, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false
      # The boot holding the claim; a mark from another boot never lands.
      add :owner, :string, null: false
      # The attempt the owner runs under this claim.
      add :attempt, :string, null: false
      # sign_in | first_need | provision | install_shipped | seed_sync
      add :entry_kind, :string, null: false
      add :lease_until, :utc_datetime_usec, null: false
      # The fencing token: 1 on the first claim, raised by one on every take.
      add :fence, :integer, null: false
      # ready | failed | released; null while the attempt holds the claim.
      add :outcome, :string
      add :outcome_detail, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:provisioning_claims, [:athanor_id])
    create index(:provisioning_claims, [:lease_until])
  end

  # ==========================================================================
  # Identity: sessions and API keys
  # ==========================================================================

  defp identity do
    # A session is a person's: what they may do is decided by their
    # memberships, the estate's consents and the policy, never by a list
    # frozen at sign-in.
    create table(:sessions, primary_key: false) do
      add :id, :string, primary_key: true
      add :token_hash, :binary, null: false
      add :token_prefix, :string
      add :user_id, :string, null: false
      add :email, :string
      add :provider, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      # The athanor the session works in. Nullable: a session exists from
      # sign-in on, before the person's own athanor is resolved.
      add :athanor_id, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:sessions, [:token_hash])
    create index(:sessions, [:user_id])
    create index(:sessions, [:expires_at])

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
      add :athanor_id, :string, null: false
      add :capability, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_keys, [:key_hash])
    create index(:api_keys, [:athanor_id])

    # Partial: a revoked key's name is immediately reusable.
    create unique_index(:api_keys, [:athanor_id, :name],
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
  # Server-wide facts
  # ==========================================================================

  # Keyed by name: the schema and keyring fingerprints. Shared by every node
  # using this database.
  defp server do
    create table(:server_meta, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :string, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end
  end

  # ==========================================================================
  # The cell
  # ==========================================================================

  # One database is one cell, and these three tables are what its members
  # share. None is an athanor's to the same degree: `cell_leases` and
  # `job_claims` describe the deployment, `rate_windows` an athanor's
  # consented allowance. Every lease here is compared against DATABASE time
  # (`Arca.ServerMetaStorage.now/0`), never a member's own clock, so two
  # members with skewed clocks still agree which lease stands.
  defp cell do
    # One row per member slot, keyed by the node's distribution name rather
    # than by a boot: a restarted node takes its own slot over instead of
    # opening a second one beside it, and its generation carries on from
    # where its predecessor left off. The row is kept after a release so a
    # returning node can never reissue a generation a worker already
    # retired.
    create table(:cell_leases, primary_key: false) do
      add :node, :string, primary_key: true
      # The boot holding the slot (`Cyfr.Boot.id/0`).
      add :owner, :string, null: false
      # What this member stamps on what it issues outward — worker
      # assignments, host-call bindings, bridge grants. Raised by one on
      # every take of THIS slot, and by no other member's join or leave.
      add :generation, :integer, null: false
      # The row's write token, raised by every write to it. A renew names
      # the fence it read, so a renew from an owner that was taken over
      # cannot land even within the deadline it still believes in.
      add :fence, :integer, null: false
      # Database time. The member holds while this stands; past it the slot
      # is takeable by anyone, which is what raises the generation.
      add :lease_until, :utc_datetime_usec, null: false
      # When the current owner took the slot, which is what a recovery-time
      # bound is measured from.
      add :taken_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cell_leases, [:lease_until])

    # The cell's singleton jobs: retention, the boot reconciliation, the
    # seed release, an OAuth refresh, a worker's watch, a backend's bridge
    # controller. A claim is a mutual-exclusion token and authorizes
    # NOTHING — its holder still
    # reads and writes through the tenant-scoped facade under its own
    # actor, so a key naming an athanor grants no reach into it.
    create table(:job_claims, primary_key: false) do
      add :id, :string, primary_key: true
      # The job (`Arca.Schemas.JobClaim.kinds/0`).
      add :kind, :string, null: false
      # What is claimed within the kind: a worker service id, an athanor's
      # credential, or "cell" for a job the cell has exactly one of.
      add :key, :string, null: false
      # The boot holding the claim.
      add :owner, :string, null: false
      add :lease_until, :utc_datetime_usec, null: false
      # 1 on the first claim, raised by one on every take.
      add :fence, :integer, null: false
      # The job's progress, carried across takeovers under the fence: the
      # worker watch's consecutive misses and the worker boot it last
      # heard, a sweep's cursor. Evidence, never authority.
      add :detail, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:job_claims, [:kind, :key])
    create index(:job_claims, [:lease_until])

    # The consented invocation rate, one row per bucket, shared by every
    # member: N members admit the consented rate once, not N times. Two
    # adjacent windows, so a claim costs one statement and no row per
    # request; the admission decision weights the prior window by how much
    # of it is still in view.
    create table(:rate_windows, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false
      # The bucket within the athanor: a component reference, or a platform
      # bucket's name.
      add :bucket, :string, null: false
      # The current window's start on database time, and the width the
      # claim that opened it consented to. A claim carrying a different
      # width opens a new window at its own: a rescaled allowance is never
      # counted against a window of another size.
      add :window_start, :utc_datetime_usec, null: false
      add :window_ms, :integer, null: false
      # Claims admitted in the current window, and in the one before it.
      add :count, :integer, null: false, default: 0
      add :prior_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:rate_windows, [:athanor_id, :bucket])
    create index(:rate_windows, [:window_start])
  end

  # ==========================================================================
  # Components and builds
  # ==========================================================================

  defp components do
    create table(:components, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :version, :string, null: false
      add :component_type, :string, null: false
      # Use text columns for values that may exceed 255 characters.
      add :description, :text
      add :tags, :text
      add :category, :string
      add :license, :string
      add :digest, :string, null: false
      add :size, :integer
      add :exports, :text
      add :publisher_id, :string
      add :publisher, :string, null: false, default: "local"
      add :source, :string, null: false, default: "published"
      add :manifest, :text
      add :signature_verified, :boolean, default: false
      add :signer_identity, :string
      add :signer_issuer, :string
      add :athanor_id, :string, null: false
      add :release_digest, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:components, [:name])
    create index(:components, [:component_type])
    create index(:components, [:publisher])
    create index(:components, [:source])
    create index(:components, [:digest])

    create unique_index(:components, [:athanor_id, :publisher, :name, :version, :component_type])

    # Build status as rows; the artifacts are blobs under the athanor's
    # components/ tree.
    create table(:build_records, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false
      add :user_id, :string, null: false
      add :reference, :string, null: false
      add :status, :string, null: false, default: "started"
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
      add :error, :text
      add :result, :text
    end

    create index(:build_records, [:athanor_id, :started_at])
  end

  # ==========================================================================
  # Storage units
  # ==========================================================================

  # A unit under a seeded root — a component version directory, an aqua
  # agent or skill (`Arca.Storage.UnitLocator`) — is published by a row:
  # the pointer names the committed, immutable revision readers see, and
  # the journal records every commit. A complete object set under the
  # unit's prefix is staging until a commit names it, and repair never
  # promotes what a losing writer staged.
  defp storage_units do
    create table(:storage_units, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false
      # The seeded root the unit lives under (`Arca.Storage.overlay_roots/0`).
      add :root, :string, null: false
      # The unit's path inside its root, segments joined with `/`.
      add :unit_key, :string, null: false
      # draft | committed | retired
      add :state, :string, null: false, default: "draft"
      # The revision the pointer names; null until the first commit.
      add :current_revision, :string
      # Held by the one writer staging the next revision; a commit
      # compares it and clears it.
      add :draft_writer_token, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:storage_units, [:athanor_id, :root, :unit_key])
    create unique_index(:storage_units, [:id, :athanor_id])
    create index(:storage_units, [:athanor_id, :state])

    # The journal: one row per commit, appended in the commit's own
    # transaction and never updated or deleted. `prior_revision` is null
    # for a unit's first commit.
    create table(:storage_commits, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false

      add :storage_unit_id,
          references(:storage_units,
            type: :string,
            on_delete: :delete_all,
            with: [athanor_id: :athanor_id]
          ),
          null: false

      add :prior_revision, :string
      add :new_revision, :string, null: false
      # The digest of the revision's content.
      add :content_identity, :string, null: false
      # Who committed: an attempt, an actor or the system, as the writer
      # spells it.
      add :commit_identity, :string, null: false
      add :committed_at, :utc_datetime_usec, null: false
    end

    create index(:storage_commits, [:storage_unit_id, :committed_at])
    create index(:storage_commits, [:athanor_id, :committed_at])
  end

  # ==========================================================================
  # Storage projections
  # ==========================================================================

  # How far each domain projection of a seeded root has caught up with the
  # root's units. A root row holds the root's epoch, raised by one in the
  # transaction of every publication, retirement, repair and edit of a unit
  # under it, and never lowered or deleted: a unit recreated after its
  # deletion takes a generation no earlier change of it held. A change row
  # holds the last generation a unit took, whether the bytes it names are
  # served yet (`ready`), the revision it names or that it was deleted
  # (`tombstone`), and the generation the projection has acknowledged. No
  # row references `storage_units`: a hand-laid unit has none, and the
  # evidence of a deletion outlives the unit's row.
  defp storage_projections do
    sqlite? = repo().__adapter__() == Ecto.Adapters.SQLite3

    epoch_positive = %{name: "storage_projection_roots_epoch_positive", expr: "epoch > 0"}

    acknowledged_epoch_counted = %{
      name: "storage_projection_roots_acknowledged_epoch_counted",
      expr: "acknowledged_epoch >= 0"
    }

    create table(:storage_projection_roots, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false
      # The seeded root (`Arca.Storage.overlay_roots/0`).
      add :root, :string, null: false
      add :epoch, :bigint, null: false, check: if(sqlite?, do: epoch_positive)

      # The epoch up to which the projection reflects every change of the
      # root.
      add :acknowledged_epoch, :bigint,
        null: false,
        default: 0,
        check: if(sqlite?, do: acknowledged_epoch_counted)
    end

    unless sqlite? do
      create constraint(:storage_projection_roots, epoch_positive.name,
               check: epoch_positive.expr
             )

      create constraint(:storage_projection_roots, acknowledged_epoch_counted.name,
               check: acknowledged_epoch_counted.expr
             )
    end

    create unique_index(:storage_projection_roots, [:athanor_id, :root])

    create table(:storage_projection_changes, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false
      add :root, :string, null: false
      # The unit's key inside its root, as `storage_units` spells it.
      add :unit_key, :string, null: false
      # The root epoch the unit's last change took.
      add :generation, :bigint, null: false
      # Whether the bytes that change names are served.
      add :ready, :boolean, null: false, default: false
      # The revision the change names; null for a deletion and for a unit
      # no commit has published.
      add :source_revision, :string
      add :tombstone, :boolean, null: false, default: false
      add :acknowledged_generation, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:storage_projection_changes, [:athanor_id, :root, :unit_key])
  end

  # ==========================================================================
  # Agents
  # ==========================================================================

  defp agents do
    # The estate's agents as rows: an index of the `aqua/` tree, one row per
    # soul or role, carrying the digest of the file's bytes (its revision)
    # and of its security-relevant subset (its capability).
    create table(:agents, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false
      add :name, :string, null: false
      # soul | role
      add :kind, :string, null: false
      add :revision_digest, :string, null: false
      add :capability_digest, :string, null: false
      add :catalyst_ref, :string
      add :disabled, :boolean, null: false, default: false
      add :synced_at, :utc_datetime_usec, null: false
    end

    create unique_index(:agents, [:athanor_id, :name])

    # Every agent file revision the index has seen, by the digest of its
    # bytes: content-addressed and immutable, so a turn that pinned a
    # revision can retrieve it after the tree moved on.
    create table(:agent_revisions, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false
      add :digest, :string, null: false
      add :bytes, :binary, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:agent_revisions, [:athanor_id, :digest])
  end

  # ==========================================================================
  # Executions, attempts, events, payloads and budgets
  # ==========================================================================

  defp executions do
    sqlite? = repo().__adapter__() == Ecto.Adapters.SQLite3

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
      add :host_policy, :text
      add :parent_execution_id, :string
      # The key the parent's runner minted for this child before asking for
      # its admission, so a lost `admit_child` answer is retried with the
      # same key and answered with this row. Null for a root.
      add :child_key, :string
      add :resolver_digest, :string
      add :athanor_id, :string, null: false
      add :activation_digest, :string
      add :activation_graph, :text
      add :root_execution_id, :string
      # The profile pinned for a root execution, so approvals reuse its authority.
      add :profile_id, :string
      # The turn an execution belongs to, and the schedule that fired it.
      add :turn_id, :string
      add :schedule_id, :string
      # component | turn | tool_call
      add :kind, :string, null: false, default: "component"
      # The attempt that currently owns the row (`execution_attempts`).
      add :current_attempt, :string
      # The durable event counter, allocated in the writer's transaction.
      add :event_seq, :integer, null: false, default: 0
    end

    create unique_index(:executions, [:id, :athanor_id])
    # One child per key under a parent: two identical admissions race here,
    # and the loser is answered with the winner's row.
    create unique_index(:executions, [:athanor_id, :parent_execution_id, :child_key])
    create index(:executions, [:started_at])
    create index(:executions, [:user_id])
    create index(:executions, [:status])
    create index(:executions, [:request_id])
    create index(:executions, [:parent_execution_id])
    create index(:executions, [:root_execution_id])
    create index(:executions, [:turn_id])
    create index(:executions, [:schedule_id])
    create index(:executions, [:athanor_id])
    create index(:executions, [:athanor_id, :started_at])
    create index(:executions, [:athanor_id, :user_id, :started_at])
    create index(:executions, [:athanor_id, :status, :started_at])
    create index(:executions, [:athanor_id, :profile_id, :started_at])
    create index(:executions, [:athanor_id, :kind, :status])

    # The fence: one row per attempt at an execution.
    # The estate standing an attempt was admitted under
    # (`Cyfr.ExecutionGrant`): the athanor's `security_generation` its
    # root read, inherited unchanged by every child and successor. No
    # default: an attempt whose admission named no generation is not
    # written. Positive, spelled once per adapter as above.
    attempt_generation = %{
      name: "execution_attempts_athanor_generation_positive",
      expr: "athanor_generation > 0"
    }

    create table(:execution_attempts, primary_key: false) do
      add :attempt, :string, primary_key: true
      add :athanor_id, :string, null: false

      add :athanor_generation, :bigint,
        null: false,
        check: if(sqlite?, do: attempt_generation)

      add :execution_id,
          references(:executions,
            type: :string,
            on_delete: :delete_all,
            with: [athanor_id: :athanor_id]
          ),
          null: false

      add :fence, :integer, null: false
      # The worker service the attempt was dispatched to (its configured
      # service id, `Cyfr.WorkerAuth`); null for an attempt the control
      # plane holds itself, such as a turn root.
      add :service_id, :string
      # The boot holding the attempt: the worker service's incarnation, or
      # this control plane's own boot for one it holds itself. A call or
      # report from another boot never touches the row.
      add :boot_id, :string, null: false
      # The runner that attached to the attempt; null until attach, and
      # always null for a turn root.
      add :claimed_by, :string
      add :lease_until, :utc_datetime_usec, null: false
      # running | paused | completed | failed | cancelled | lapsed
      add :state, :string, null: false
      # ok | error | result_lost | cancelled | uncertain
      add :outcome, :string
      add :started_at, :utc_datetime_usec, null: false
      add :running_since, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
    end

    unless sqlite? do
      create constraint(:execution_attempts, attempt_generation.name,
               check: attempt_generation.expr
             )
    end

    create unique_index(:execution_attempts, [:execution_id, :fence])
    create index(:execution_attempts, [:athanor_id, :state, :lease_until])
    create index(:execution_attempts, [:claimed_by], where: "state = 'running'")
    create index(:execution_attempts, [:service_id, :boot_id], where: "state = 'running'")

    # The evidence of a guest's mutable storage writes: one row per write,
    # recorded while its attempt held its row and before the store was
    # touched, settled once the store answered or the attempt lost its row.
    create table(:storage_write_intents, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false

      add :execution_id,
          references(:executions,
            type: :string,
            on_delete: :delete_all,
            with: [athanor_id: :athanor_id]
          ),
          null: false

      # The attempt that wrote, the fence it held and the runner that
      # claimed it.
      add :attempt, :string, null: false
      add :fence, :integer, null: false
      add :runner, :string, null: false
      # put | append | delete
      add :op, :string, null: false
      # The athanor-relative path the write names.
      add :path, :text, null: false
      # The bytes a put or append carried; null for a delete.
      add :bytes, :integer
      # pending | confirmed | failed | uncertain
      add :state, :string, null: false
      # Why a failed or uncertain intent settled as it did.
      add :reason, :string
      add :inserted_at, :utc_datetime_usec, null: false
      add :settled_at, :utc_datetime_usec
    end

    create index(:storage_write_intents, [:athanor_id, :attempt, :state])
    create index(:storage_write_intents, [:athanor_id, :state, :inserted_at])

    # Lifecycle and step outcomes, numbered from `executions.event_seq`.
    create table(:execution_events, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false

      add :execution_id,
          references(:executions,
            type: :string,
            on_delete: :delete_all,
            with: [athanor_id: :athanor_id]
          ),
          null: false

      add :turn_id, :string
      add :step_id, :string
      add :seq, :integer, null: false
      add :type, :string, null: false
      add :data, :text
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:execution_events, [:execution_id, :seq])
    create index(:execution_events, [:athanor_id, :turn_id])

    # An execution's retained input or result, as a reference: the digest
    # and size of the bytes, where they live under the athanor's `payloads/`
    # root, the attempt that produced them and the retention class that
    # decides how long. Bytes are removed before their rows permit the
    # execution's deletion.
    create table(:execution_payloads, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false

      add :execution_id,
          references(:executions,
            type: :string,
            on_delete: :nothing,
            with: [athanor_id: :athanor_id]
          ),
          null: false

      # input | result
      add :kind, :string, null: false
      add :attempt, :string
      add :digest, :string, null: false
      add :bytes, :integer, null: false
      add :blob_ref, :string, null: false
      add :retention_class, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:execution_payloads, [:execution_id, :kind, :attempt])
    create index(:execution_payloads, [:athanor_id, :retention_class, :inserted_at])

    create table(:budget_reservations, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false

      add :root_execution_id,
          references(:executions,
            type: :string,
            on_delete: :delete_all,
            with: [athanor_id: :athanor_id]
          ),
          null: false

      add :kind, :string, null: false, default: "invoke"
      add :cap, :integer, null: false
      add :charged, :integer, null: false, default: 0
      add :inserted_at, :utc_datetime_usec, null: false
      add :released_at, :utc_datetime_usec
    end

    create index(:budget_reservations, [:athanor_id, :root_execution_id])

    create table(:budget_charges, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false

      add :reservation_id,
          references(:budget_reservations, type: :string, on_delete: :delete_all),
          null: false

      add :attempt, :string, null: false
      add :generation, :integer, null: false, default: 0
      add :holder_execution_id, :string
      add :n, :integer, null: false
      add :runner_id, :string, null: false
      add :admit_by, :utc_datetime_usec
      add :admitted_at, :utc_datetime_usec
      add :holder_deadline, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:budget_charges, [:reservation_id, :id])
    create index(:budget_charges, [:athanor_id, :attempt])
    create index(:budget_charges, [:athanor_id, :holder_execution_id])
  end

  # ==========================================================================
  # Audit logs
  # ==========================================================================

  defp logs do
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
      add :athanor_id, :string, null: false
      # The ingress request a call belongs to; a chain shares one.
      add :request_id, :string
    end

    create index(:mcp_logs, [:user_id])
    create index(:mcp_logs, [:timestamp])
    create index(:mcp_logs, [:status])
    create index(:mcp_logs, [:request_id])
    create index(:mcp_logs, [:athanor_id])
    create index(:mcp_logs, [:athanor_id, :timestamp])

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
      add :athanor_id, :string, null: false
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
    create index(:policy_logs, [:athanor_id])
    create index(:policy_logs, [:athanor_id, :timestamp])
    create index(:policy_logs, [:consent_id])
  end

  # ==========================================================================
  # Retention settings
  # ==========================================================================

  # One row per athanor: the retention values it has set, as the RFC 8785
  # encoding of a map from retention key to a positive integer
  # (`Arca.RetentionSettings`). A patch lands only while the row still
  # holds the revision it read, so two patches of different keys both
  # land. Positive, starting at 1; spelled once per adapter for the same
  # reason as the standing counters.
  defp retention do
    sqlite? = repo().__adapter__() == Ecto.Adapters.SQLite3

    revision_positive = %{name: "retention_settings_revision_positive", expr: "revision > 0"}

    create table(:retention_settings, primary_key: false) do
      add :athanor_id, :string, primary_key: true, null: false
      add :settings, :text, null: false
      add :revision, :bigint, null: false, check: if(sqlite?, do: revision_positive)

      timestamps(type: :utc_datetime_usec)
    end

    unless sqlite? do
      create constraint(:retention_settings, revision_positive.name,
               check: revision_positive.expr
             )
    end
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
      add :athanor_id, :string, null: false
      add :name, :string, null: false
      add :provider_hint, :string, null: false, default: ""
      add :kind, :string, null: false
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

    create unique_index(:vault_entries, [:athanor_id, :id])

    create unique_index(:vault_entries, [:athanor_id, :name],
             where: "status != 'tombstoned'",
             name: :vault_entries_active_name_index
           )

    create table(:profiles, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false
      add :source_ref, :string, null: false
      add :kind, :string, null: false, default: "owner"
      add :label, :string, null: false, default: "default"
      add :status, :string, null: false, default: "active"
      add :head_consent_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:profiles, [:athanor_id, :id])

    create unique_index(:profiles, [:athanor_id, :source_ref, :label, :kind],
             where: "status != 'revoked'",
             name: :profiles_active_identity_index
           )

    create index(:profiles, [:athanor_id, :source_ref])

    # Insert-only: a revision that exists but is not the head is history.
    create table(:consents, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false

      add :profile_id,
          references(:profiles, column: :id, type: :string, with: [athanor_id: :athanor_id]),
          null: false

      add :revision, :integer, null: false
      add :scope, :string, null: false
      add :pinned_version, :string, null: false, default: ""
      add :invoke_mode, :string, null: false, default: "open_inert"
      add :shape_digest, :string, null: false
      add :commit_digest, :string, null: false
      add :resolved_policy, :binary, null: false
      # The digest of `resolved_policy`'s bytes, verified on every load.
      add :blob_digest, :string, null: false
      add :activation, :binary, null: false
      add :granted_by, :string, null: false
      add :granted_via, :string, null: false
      add :granted_at, :utc_datetime_usec, null: false
      add :supersedes_id, :string
    end

    create index(:consents, [:athanor_id, :profile_id])
    create unique_index(:consents, [:profile_id, :revision])

    create table(:consent_vault_refs, primary_key: false) do
      add :consent_id, references(:consents, column: :id, type: :string), null: false
      add :athanor_id, :string, null: false

      add :vault_entry_id,
          references(:vault_entries, column: :id, type: :string, with: [athanor_id: :athanor_id]),
          null: false

      add :binding_digest, :string, null: false
    end

    create unique_index(:consent_vault_refs, [:consent_id, :vault_entry_id])
    create index(:consent_vault_refs, [:vault_entry_id, :athanor_id])

    # Single-use, delete-on-read. No foreign keys by design: a proof outlives
    # the plan it came from and must not be cascaded away.
    create table(:consent_proofs, primary_key: false) do
      add :token_hash, :string, primary_key: true
      add :kind, :string, null: false
      add :digest, :string, null: false
      add :bindings, :text, null: false, default: "{}"
      add :athanor_id, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:consent_proofs, [:expires_at])

    create table(:oauth_provider_credentials, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false
      add :provider, :string, null: false
      add :payload_ciphertext, :binary, null: false
      add :created_by, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:oauth_provider_credentials, [:athanor_id, :provider])

    # Athanor-scoped tool decisions, kept apart from authored agent policy:
    # effective policy is the declared permissions plus allows, minus denies.
    # An agent-scope grant applies across threads; a thread-scope
    # grant only to the named one. Each scope has its own unique index,
    # because agent rows carry no thread id and a nullable composite
    # key would permit duplicates; effect is not in either key, so flipping
    # allow/deny updates one row.
    create table(:tool_grants, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false
      add :scope, :string, null: false
      add :effect, :string, null: false
      add :thread_id, :string
      add :agent_name, :string, null: false
      add :tool, :string, null: false
      add :action, :string, null: false
      add :granted_by, :string
      add :granted_at, :utc_datetime_usec, null: false
    end

    # Each partial key is named for its scope, the name Postgres reports a
    # violation under. SQLite reports a violation by column, so
    # `Arca.ToolGrantStorage` declares each constraint under both spellings.
    create unique_index(
             :tool_grants,
             [:thread_id, :agent_name, :tool, :action],
             where: "scope = 'thread'",
             name: :tool_grants_thread_scope_index
           )

    create unique_index(
             :tool_grants,
             [:athanor_id, :agent_name, :tool, :action],
             where: "scope = 'agent'",
             name: :tool_grants_agent_scope_index
           )

    create index(:tool_grants, [:athanor_id, :agent_name])
  end

  # ==========================================================================
  # Standing invocation channels
  # ==========================================================================

  defp registrations do
    # An `http` server has a url; a `stdio` server has none and runs its
    # backends (`config_json.backends`) on the MCP bridge. `epoch` is 1 on
    # insert and rises in the same statement as every change to the row.
    # SQLite takes a check only inside CREATE TABLE and Postgres only as a
    # table constraint, so the one rule is spelled once per adapter.
    transport_check = %{
      name: "mcp_servers_transport_url",
      expr: "(transport = 'http' AND url IS NOT NULL) OR (transport = 'stdio' AND url IS NULL)"
    }

    sqlite? = repo().__adapter__() == Ecto.Adapters.SQLite3

    create table(:mcp_servers, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :transport, :string, null: false, check: if(sqlite?, do: transport_check)
      add :url, :string
      add :config_json, :text, null: false
      add :enabled, :boolean, default: true
      add :epoch, :bigint, null: false
      # The person who created the row; their stdio servers share one quota
      # of the MCP bridge across every athanor.
      add :created_by, :string, null: false
      add :athanor_id, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    unless sqlite? do
      create constraint(:mcp_servers, transport_check.name, check: transport_check.expr)
    end

    create unique_index(:mcp_servers, [:athanor_id, :name])

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
      add :athanor_id, :string, null: false
      add :timestamp_header, :string
      add :idempotency_key_header, :string
      add :previous_secret_encrypted, :binary
      add :previous_secret_expires_at, :utc_datetime_usec
      add :profile_id, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # The slug is a random address; its uniqueness is global by nature.
    create unique_index(:webhooks, [:slug])
    create unique_index(:webhooks, [:athanor_id, :name])

    # A claimed or succeeded delivery holds its idempotency claim; a failed
    # one can be reclaimed by a retry.
    create table(:webhook_deliveries, primary_key: false) do
      add :id, :string, primary_key: true

      add :webhook_id,
          references(:webhooks, type: :string, on_delete: :delete_all),
          null: false

      add :idempotency_key, :string, null: false
      add :first_seen_at, :utc_datetime_usec, null: false
      # claimed | succeeded | failed
      add :status, :string, null: false, default: "claimed"
      add :settled_at, :utc_datetime_usec
    end

    create unique_index(:webhook_deliveries, [:webhook_id, :idempotency_key])
    create index(:webhook_deliveries, [:first_seen_at])
    # Which claims never settled — how a stuck delivery is found.
    create index(:webhook_deliveries, [:status, :first_seen_at])
  end

  # ==========================================================================
  # Schedules
  # ==========================================================================

  defp schedules do
    create table(:cron_schedules, primary_key: false) do
      add :id, :string, primary_key: true
      # Attribution: who created the schedule. The athanor owns it.
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
      add :athanor_id, :string, null: false
      add :profile_id, :string, null: false
      # forbid | allow: whether a due occurrence may be claimed while another
      # of the same schedule is still open.
      add :concurrency, :string, null: false, default: "forbid"
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:cron_schedules, [:id, :athanor_id])
    create index(:cron_schedules, [:status])
    create index(:cron_schedules, [:next_run_at])
    create index(:cron_schedules, [:athanor_id])

    create unique_index(:cron_schedules, [:athanor_id, :name],
             where: "status != 'deleted'",
             name: :cron_schedules_athanor_name_active
           )

    # An occurrence of a schedule is a row of its own: claimed by one node
    # (the cursor moves in the same write), started by the execution's
    # admission, ended with the run.
    create table(:schedule_occurrences, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false

      add :schedule_id,
          references(:cron_schedules,
            type: :string,
            on_delete: :delete_all,
            with: [athanor_id: :athanor_id]
          ),
          null: false

      add :scheduled_for, :utc_datetime_usec, null: false
      # claimed | started | completed | failed | uncertain
      add :state, :string, null: false
      add :execution_id, :string
      add :attempts, :integer, null: false, default: 0
      add :claimed_by, :string
      add :claimed_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
    end

    create unique_index(:schedule_occurrences, [:schedule_id, :scheduled_for])
    create index(:schedule_occurrences, [:athanor_id, :state])
  end

  # ==========================================================================
  # Threads
  # ==========================================================================

  # A thread belongs to the athanor; every member sees the same thread.
  # Rows are the shared, durable record — no browser session owns a turn.
  defp threads do
    create table(:threads, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false
      add :title, :string, null: false, default: "New thread"
      # Attribution: the person who opened it. The athanor owns it.
      add :created_by, :string, null: false
      # The agent the last turn addressed.
      add :agent, :string
      # `seq` of the last human message a turn has taken up: the consumed
      # message sequence, and the value a thread claim compares against.
      add :turn_seq, :integer, null: false, default: 0
      # The turn holding the thread, null when none does. Claiming is one
      # statement: it names the turn AND the `turn_seq` the claimant read,
      # so a claim whose sequence moved under it — another member accepted
      # the next message first — writes nothing. A plain string, not a
      # reference: `turns.thread_id` already points the other way, and a
      # second edge back would be a cycle no adapter deletes cleanly.
      add :active_turn_id, :string
      add :last_message_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:threads, [:id, :athanor_id])
    create index(:threads, [:athanor_id, :last_message_at])

    # One turn holds at most one thread. Partial, so the null of a thread
    # nobody is working costs nothing and does not collide.
    create unique_index(:threads, [:active_turn_id], where: "active_turn_id IS NOT NULL")

    create table(:messages, primary_key: false) do
      add :id, :string, primary_key: true

      add :thread_id,
          references(:threads, type: :string, on_delete: :delete_all),
          null: false

      add :athanor_id, :string, null: false
      # Position in the thread; assigned by the runner, dense per thread.
      add :seq, :integer, null: false
      # Who wrote it: a user id, an agent, or "system".
      add :author, :string, null: false
      # text | approval | error | system | tool_call | tool_result |
      # compaction | turn_aborted
      add :kind, :string, null: false, default: "text"
      add :content, :text, null: false, default: ""
      # Kind-specific JSON: an approval's intent and proposal, a text
      # message's attachment refs (bytes under
      # data/athanors/{athanor_id}/threads/{thread}/{msg}/), an error's
      # source.
      add :payload, :text
      # Approvals: pending | running | approved | declined | error.
      add :status, :string
      add :resolved_by, :string
      add :resolved_at, :utc_datetime_usec
      # Approvals: the decision's reason/result summary/scope, JSON.
      add :resolution, :text
      add :execution_id, :string
      add :turn_id, :string
      add :approval_id, :string
      # The sender's retry identity.
      add :client_id, :string
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:messages, [:thread_id, :seq])
    create unique_index(:messages, [:thread_id, :client_id], where: "client_id IS NOT NULL")
    create index(:messages, [:athanor_id, :inserted_at])
    create index(:messages, [:athanor_id, :turn_id])
    create index(:messages, [:thread_id, :status])

    # Follows for each member's sidebar: display only; membership still
    # decides access.
    create table(:thread_subscriptions, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false
      add :thread_id, :string, null: false
      add :user_id, :string, null: false
      add :joined_at, :utc_datetime_usec, null: false
    end

    create unique_index(:thread_subscriptions, [:thread_id, :user_id])
    create index(:thread_subscriptions, [:athanor_id, :user_id])
  end

  # ==========================================================================
  # Turns
  # ==========================================================================

  # `turns` own accepted work and its state; `turn_steps` own orchestration
  # state and reference content by message and execution id, never
  # duplicating it; `approvals` own a decision, which the corresponding
  # message row references. Columns naming an execution or a turn beyond
  # the composite parents are plain strings: the tenant seam holds every
  # query to `athanor_id`.
  defp turns do
    create table(:turns, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false

      add :thread_id,
          references(:threads,
            type: :string,
            on_delete: :delete_all,
            with: [athanor_id: :athanor_id]
          ),
          null: false

      add :agent, :string
      add :requested_by, :string
      add :status, :string, null: false
      add :error, :text
      add :accepted_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
      add :parent_turn_id, :string
      add :message_id, :string
      add :root_execution_id, :string
      add :attempt, :string
      add :runner_id, :string
      # The turn's fencing token: 1 when the turn is opened, raised by one
      # by every host transition that takes the turn from its holder.
      add :fence, :integer, null: false
      add :recovery_attempts, :integer, null: false, default: 0
      add :profile_id, :string
      add :consent_id, :string
      add :agent_revision_digest, :string
      add :agent_capability_digest, :string
      add :budget_id, :string
      add :model, :string
      # The exact catalyst release the turn runs on, pinned at its first build.
      add :catalyst_ref, :string
      add :options, :text
      # The consumption boundary: the transcript a turn reads.
      add :window_upto_seq, :integer
      add :active_ms, :integer, null: false, default: 0
      add :paused_at, :utc_datetime_usec
      # approval | launch
      add :paused_reason, :string
      add :launch_step_id, :string
    end

    create unique_index(:turns, [:id, :athanor_id])
    create index(:turns, [:athanor_id, :thread_id, :accepted_at])
    create index(:turns, [:athanor_id, :status])
    create index(:turns, [:athanor_id, :parent_turn_id])
    create unique_index(:turns, [:thread_id, :message_id], where: "message_id IS NOT NULL")

    create unique_index(:turns, [:root_execution_id],
             where: "root_execution_id IS NOT NULL AND parent_turn_id IS NULL"
           )

    create table(:turn_steps, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false

      add :turn_id,
          references(:turns,
            type: :string,
            on_delete: :delete_all,
            with: [athanor_id: :athanor_id]
          ),
          null: false

      add :seq, :integer, null: false
      # model | tool | ui | approval | clone | launch
      add :kind, :string, null: false
      # chat | flush | compaction — what the step serves, set by the host
      add :purpose, :string, null: false
      add :idempotency_key, :string
      add :tool, :string
      add :action, :string
      # proposed | dispatched | closed | uncertain
      add :dispatch_state, :string, null: false, default: "proposed"
      add :message_id, :string
      add :result_message_id, :string
      add :execution_id, :string
      add :child_execution_id, :string
      add :approval_id, :string
      add :authority_digest, :string
      add :proposal_digest, :string
      add :request_digest, :string
      add :usage, :text
      add :excluded, :text
      # nil | replay_safe
      add :recovery, :string
      add :generation, :integer, null: false, default: 0
      add :cancel_requested_at, :utc_datetime_usec
      # ok | error | denied | skipped
      add :outcome, :string
      add :error, :text
      add :started_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
    end

    create unique_index(:turn_steps, [:turn_id, :seq])
    create unique_index(:turn_steps, [:id, :athanor_id])
    create index(:turn_steps, [:athanor_id, :turn_id])
    create index(:turn_steps, [:athanor_id, :dispatch_state])

    create table(:approvals, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false

      add :turn_id,
          references(:turns,
            type: :string,
            on_delete: :delete_all,
            with: [athanor_id: :athanor_id]
          ),
          null: false

      add :thread_id, :string
      add :step_id, :string
      add :message_id, :string
      # pending | approved | declined | expired | error
      add :status, :string, null: false
      add :scope, :string
      add :proposal_digest, :string, null: false
      # continue | launch | denied | expired
      add :resolution_kind, :string
      add :launch_execution_id, :string
      add :decided_by, :string
      add :decided_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
      add :resolution, :text
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:approvals, [:id, :athanor_id])
    create index(:approvals, [:athanor_id, :status])
    create index(:approvals, [:athanor_id, :turn_id])
    create index(:approvals, [:athanor_id, :thread_id, :status])
    create index(:approvals, [:athanor_id, :status, :expires_at])
  end

  # The schema this database was built from, recorded by the migration that
  # built it (`Arca.SchemaFingerprint`).
  defp record_fingerprint do
    flush()

    repo().insert_all(Arca.Schemas.ServerMeta, [
      %{
        key: Arca.SchemaFingerprint.key(),
        value: Arca.SchemaFingerprint.current(),
        updated_at: DateTime.utc_now()
      }
    ])
  end
end
