# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.AddRootExecutionIdToExecutions do
  use Ecto.Migration

  # Lineage in one column: parent_execution_id gives the immediate parent,
  # but "is this execution in my chain" needs the root, and walking parents
  # per check would be a query per level. A root row stamps itself, so the
  # predicate is one comparison. Legacy rows stay NULL and fail closed for
  # in-chain callers.
  def change do
    alter table(:executions) do
      add :root_execution_id, :string
    end

    create index(:executions, [:root_execution_id])
  end
end
