# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.CreateCronSchedules do
  use Ecto.Migration

  def change do
    create table(:cron_schedules, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, :string, null: false
      add :name, :string, null: false
      add :cron_expression, :string, null: false
      add :reference, :string, null: false
      add :input, :string
      add :metadata, :string
      add :status, :string, null: false, default: "active"
      add :last_run_at, :utc_datetime_usec
      add :next_run_at, :utc_datetime_usec
      add :last_execution_id, :string
      add :run_count, :integer, null: false, default: 0
      add :error_count, :integer, null: false, default: 0
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:cron_schedules, [:user_id])
    create index(:cron_schedules, [:status])
    create index(:cron_schedules, [:next_run_at])

    create unique_index(:cron_schedules, [:user_id, :name],
             where: "status != 'deleted'",
             name: :cron_schedules_user_name_active
           )
  end
end
