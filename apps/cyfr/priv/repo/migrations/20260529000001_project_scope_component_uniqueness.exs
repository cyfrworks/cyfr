# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.ProjectScopeComponentUniqueness do
  use Ecto.Migration

  # Component identity is (publisher, name, version, component_type, org_id,
  # project_id) — the same fields the comp_<hash> id is derived from. Two stale
  # unique indexes predate the project dimension and would block per-project
  # rows:
  #   * [:publisher, :name, :version, :component_type, :org_id] — org-only,
  #     so two projects in one org collide on the same component.
  #   * [:name, :version, :publisher, :org_id, :project_id] — omits
  #     component_type, so a catalyst and a tincture sharing a name collide.
  # Replace both with the full, type- and project-inclusive index.

  def up do
    drop_if_exists unique_index(:components, [
                     :publisher,
                     :name,
                     :version,
                     :component_type,
                     :org_id
                   ])

    drop_if_exists unique_index(:components, [:name, :version, :publisher, :org_id, :project_id])

    create unique_index(
             :components,
             [:publisher, :name, :version, :component_type, :org_id, :project_id]
           )
  end

  def down do
    drop_if_exists unique_index(
                     :components,
                     [:publisher, :name, :version, :component_type, :org_id, :project_id]
                   )

    create unique_index(:components, [:publisher, :name, :version, :component_type, :org_id])
    create unique_index(:components, [:name, :version, :publisher, :org_id, :project_id])
  end
end
