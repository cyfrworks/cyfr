# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.DropPlanFromOrgs do
  @moduledoc """
  Drop the vestigial `plan` column from `orgs`.

  The column existed only to index an optional plan-ceiling cascade that has
  been removed; nothing else consumed it. Resource limits are now a single
  platform ceiling. Runs after the seed migration, which still writes the
  column, so the historical migrations remain valid.
  """

  use Ecto.Migration

  def up do
    alter table(:orgs) do
      remove :plan
    end
  end

  def down do
    alter table(:orgs) do
      add :plan, :string, null: false, default: "free"
    end
  end
end
