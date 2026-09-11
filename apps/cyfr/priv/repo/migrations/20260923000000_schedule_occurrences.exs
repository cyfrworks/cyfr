# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.ScheduleOccurrences do
  use Ecto.Migration

  # An occurrence of a schedule is a row of its own: claimed by one node
  # (the cursor moves in the same write), started by the execution's
  # admission, ended with the run. The liveness marker on the schedule
  # row goes; `concurrency` says whether a due occurrence may be claimed
  # while another of the same schedule is still open.
  def up do
    create unique_index(:cron_schedules, [:id, :athanor_id])

    alter table(:cron_schedules) do
      add :concurrency, :string, null: false, default: "forbid"
      remove :claimed_by
      remove :claim_expires_at
    end

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

  def down do
    drop table(:schedule_occurrences)

    alter table(:cron_schedules) do
      remove :concurrency
      add :claimed_by, :string
      add :claim_expires_at, :utc_datetime_usec
    end

    drop unique_index(:cron_schedules, [:id, :athanor_id])
  end
end
