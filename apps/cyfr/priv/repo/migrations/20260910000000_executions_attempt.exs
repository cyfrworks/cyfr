# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.ExecutionsAttempt do
  use Ecto.Migration

  # Adds an attempt id for execution write fencing. Renewal, completion,
  # and sweeping match the attempt; sweeps also match the observed lease.
  # Rows without an attempt id retain status-based fencing.
  def up do
    alter table(:executions) do
      add :attempt, :string
    end
  end

  def down do
    alter table(:executions) do
      remove :attempt
    end
  end
end
