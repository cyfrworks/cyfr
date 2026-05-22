# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.AddFormulaParallelismFields do
  use Ecto.Migration

  def change do
    alter table(:policies) do
      add :batch_timeout, :string, default: "5m"
      add :max_concurrent_tasks, :integer, default: 10
    end
  end
end
