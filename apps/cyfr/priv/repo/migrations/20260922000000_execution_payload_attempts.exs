# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.ExecutionPayloadAttempts do
  use Ecto.Migration

  # A payload row names the attempt that produced it: one row per
  # execution, kind and attempt. Rows written before the column existed
  # belong to their execution's current attempt.
  def up do
    alter table(:execution_payloads) do
      add :attempt, :string
    end

    execute """
    UPDATE execution_payloads SET attempt = (
      SELECT e.current_attempt FROM executions e
      WHERE e.id = execution_payloads.execution_id
        AND e.athanor_id = execution_payloads.athanor_id
    )
    """

    drop unique_index(:execution_payloads, [:execution_id, :kind])
    create unique_index(:execution_payloads, [:execution_id, :kind, :attempt])
  end

  def down do
    drop unique_index(:execution_payloads, [:execution_id, :kind, :attempt])

    execute """
    DELETE FROM execution_payloads WHERE id IN (
      SELECT p.id FROM execution_payloads p
      JOIN executions e ON e.id = p.execution_id AND e.athanor_id = p.athanor_id
      WHERE p.attempt IS NOT NULL AND p.attempt <> e.current_attempt
    )
    """

    create unique_index(:execution_payloads, [:execution_id, :kind])

    alter table(:execution_payloads) do
      remove :attempt
    end
  end
end
