# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Arca.Repo.Migrations.AddActivationToExecutions do
  use Ecto.Migration

  # Which code actually ran. `activation_digest` is recorded on every row
  # that can resolve one; the full node -> release-digest map is recorded on
  # root rows only, since a child's graph is a subgraph of its root's.
  # Both nullable: pre-existing rows and components without release digests
  # keep NULL, and nothing reads these yet.
  def change do
    alter table(:executions) do
      add :activation_digest, :string
      add :activation_graph, :text
    end
  end
end
