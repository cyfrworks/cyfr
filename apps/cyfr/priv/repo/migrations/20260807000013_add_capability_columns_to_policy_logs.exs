# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.AddCapabilityColumnsToPolicyLogs do
  use Ecto.Migration

  # §4.5: store the runtime facts, derive the rest. These seven are what
  # only the running chain knows; granted_by/at/via, override, profile_kind
  # and source_ref are JOINED from the immutable consent at read rather
  # than copied onto a row written synchronously in the hot path.
  #
  # All nullable: legacy-path enforcement rows carry none of it. No FK to
  # consents — an audit row must survive whatever happens to what it
  # describes.
  def change do
    alter table(:policy_logs) do
      add :consent_id, :string
      add :activation_digest, :string
      add :dep_ref, :string
      add :need, :string
      add :cursor_state, :string
      add :chain, :text
      add :value_source, :string
    end

    create index(:policy_logs, [:consent_id])
  end
end
