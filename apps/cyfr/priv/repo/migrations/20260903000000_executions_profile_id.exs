# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.ExecutionsProfileId do
  use Ecto.Migration

  # Which profile an execution ran as was nowhere on the row.
  #
  # `executions` recorded the reference, the component digest and the
  # activation digest — what CODE ran — but never which consent it ran
  # under. That was survivable while a source ref had exactly one owner
  # profile, because `Sanctum.Authority.RootSelect.select/2` could always
  # re-derive it. It stops being survivable the moment a second profile
  # exists on the same ref: the active-identity index is
  # `(athanor_id, source_ref, label, kind)`, so two owner labels already
  # make that re-derivation `{:ambiguous, _}`.
  #
  # The concrete bug this closes is in the chat harness. A turn resolved a
  # profile implicitly, and then `Aqua.Turn.run_approved/2` re-derived one
  # implicitly a second time when the human approved a call — two
  # independent resolutions of "which authority", with nothing tying them
  # together. Pinning the id on the row makes the turn's authority a fact
  # the approval reads rather than a lookup it repeats.
  #
  # Nullable: a child row in a chain roots no profile of its own (it walks
  # its parent's authority), and the pre-capability rows predate the
  # column entirely.
  def up do
    alter table(:executions) do
      add :profile_id, :string
    end

    # "What has this grant actually done?" — the lender's-ledger question,
    # and the one a person asks before revoking a profile.
    create index(:executions, [:athanor_id, :profile_id, :started_at])
  end

  def down do
    drop index(:executions, [:athanor_id, :profile_id, :started_at])

    alter table(:executions) do
      remove :profile_id
    end
  end
end
