# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.BuildRecords do
  use Ecto.Migration

  # Build status becomes a row like every other structured record
  # (executions, MCP logs, policy logs) — it was the last "JSON file that
  # is really a record". The WASM/tincture artifacts a build produces stay
  # blobs under the athanor's components/ tree.
  def change do
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
end
