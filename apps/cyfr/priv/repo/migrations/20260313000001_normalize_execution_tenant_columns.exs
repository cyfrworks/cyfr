# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.NormalizeExecutionTenantColumns do
  use Ecto.Migration

  def up do
    execute "UPDATE executions SET org_id = '' WHERE org_id IS NULL"
    execute "UPDATE executions SET project_id = 'default' WHERE project_id IS NULL"
  end

  def down do
    # Cannot reliably distinguish originally-NULL from sentinel values
    :ok
  end
end
