# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.AddRequestIdToExecutions do
  use Ecto.Migration

  def change do
    alter table(:executions) do
      add :request_id, :string
    end

    create index(:executions, [:request_id])
  end
end
