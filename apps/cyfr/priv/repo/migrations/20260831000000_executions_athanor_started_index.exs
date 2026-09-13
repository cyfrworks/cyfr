# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.ExecutionsAthanorStartedIndex do
  use Ecto.Migration

  # Index executions by athanor_id and started_at for retention’s
  # ordered per-athanor queries.
  def change do
    create index(:executions, [:athanor_id, :started_at])
  end
end
