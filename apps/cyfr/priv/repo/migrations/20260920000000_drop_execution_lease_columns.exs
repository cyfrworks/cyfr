# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.DropExecutionLeaseColumns do
  use Ecto.Migration

  # The engine reads and writes the attempt row now: the lease columns on
  # `executions` go. Rows a legacy writer opened after the attempts table
  # was created are given their attempt first, so nothing running is
  # left without an owner.
  def up do
    execute """
    INSERT INTO execution_attempts
      (attempt, athanor_id, execution_id, fence, runner_id, lease_until, state, outcome,
       started_at, running_since, ended_at)
    SELECT
      COALESCE(attempt, 'att_legacy_' || id),
      athanor_id,
      id,
      1,
      COALESCE(runner_id, ''),
      COALESCE(lease_until, started_at),
      status,
      CASE status
        WHEN 'completed' THEN 'ok'
        WHEN 'failed' THEN 'error'
        WHEN 'cancelled' THEN 'cancelled'
        ELSE NULL
      END,
      started_at,
      CASE status WHEN 'running' THEN started_at ELSE NULL END,
      completed_at
    FROM executions
    WHERE current_attempt IS NULL
    """

    execute """
    UPDATE executions
    SET current_attempt = COALESCE(attempt, 'att_legacy_' || id)
    WHERE current_attempt IS NULL
    """

    drop index(:executions, [:status, :lease_until])

    alter table(:executions) do
      remove :attempt
      remove :runner_id
      remove :lease_until
    end
  end

  def down do
    alter table(:executions) do
      add :attempt, :string
      add :runner_id, :string
      add :lease_until, :utc_datetime_usec
    end

    create index(:executions, [:status, :lease_until])

    execute """
    UPDATE executions SET attempt = current_attempt
    """
  end
end
