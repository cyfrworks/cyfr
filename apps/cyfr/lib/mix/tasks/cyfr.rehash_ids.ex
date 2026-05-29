# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Mix.Tasks.Cyfr.RehashIds do
  @moduledoc """
  Recompute component IDs to include tenant fields in the hash.

  The ID formula changed from `sha256("publisher:name:version:component_type")` to
  `sha256("org_id:project_id:publisher:name:version:component_type")`. This task
  reads every component row, computes the new ID, and replaces the row when the
  ID differs. Dependency foreign keys are updated in the same transaction.

  SQLite does not support primary-key updates, so each changed row is deleted
  and re-inserted in a transaction.

  ## Usage

      mix cyfr.rehash_ids          # preview changes (dry run)
      mix cyfr.rehash_ids --apply  # apply changes

  """
  use Mix.Task

  require Arca.Repo.Errors
  import Ecto.Query

  @shortdoc "Recompute component IDs to include component_type in hash"

  @impl Mix.Task
  def run(args) do
    apply? = "--apply" in args

    Mix.Task.run("app.start")

    rows = list_all_components()
    Mix.shell().info("Found #{length(rows)} component(s) in the database.")

    changes =
      rows
      |> Enum.map(fn row ->
        old_id = row.id

        new_id =
          Compendium.ComponentId.compute(
            row.name,
            row.version,
            row.publisher,
            row.component_type,
            row.org_id,
            row.project_id
          )

        {row, old_id, new_id}
      end)
      |> Enum.filter(fn {_row, old_id, new_id} -> old_id != new_id end)

    if changes == [] do
      Mix.shell().info("All component IDs are up to date. Nothing to do.")
    else
      Mix.shell().info("#{length(changes)} component(s) need ID rehashing:\n")

      for {row, old_id, new_id} <- changes do
        Mix.shell().info(
          "  #{row.component_type}:#{row.publisher}.#{row.name}:#{row.version}\n" <>
            "    old: #{old_id}\n" <>
            "    new: #{new_id}\n"
        )
      end

      if apply? do
        Mix.shell().info("Applying changes...")

        Arca.Repo.transaction(fn ->
          for {row, old_id, new_id} <- changes do
            delete_by_id(old_id)
            update_dependency_fks(old_id, new_id)
            insert_component(Map.put(row, :id, new_id))
          end
        end)
        |> case do
          {:ok, _} ->
            Mix.shell().info("Successfully rehashed #{length(changes)} component ID(s).")

          {:error, reason} ->
            Mix.shell().error("Transaction failed: #{inspect(reason)}")
        end
      else
        Mix.shell().info("Dry run — pass --apply to commit these changes.")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp list_all_components do
    from(c in "components",
      select: %{
        id: c.id,
        name: c.name,
        version: c.version,
        component_type: c.component_type,
        description: c.description,
        tags: c.tags,
        category: c.category,
        license: c.license,
        digest: c.digest,
        size: c.size,
        exports: c.exports,
        publisher: c.publisher,
        publisher_id: c.publisher_id,
        org_id: c.org_id,
        project_id: c.project_id,
        source: c.source,
        inserted_at: c.inserted_at,
        updated_at: c.updated_at
      }
    )
    |> Arca.Repo.all()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Mix.shell().error("[RehashIds] Failed to list components: #{Exception.message(e)}")
      []
  end

  defp delete_by_id(id) do
    from(c in "components", where: c.id == ^id)
    |> Arca.Repo.delete_all()
  end

  defp update_dependency_fks(old_id, new_id) do
    from(d in "component_dependencies", where: d.component_id == ^old_id)
    |> Arca.Repo.update_all(set: [component_id: new_id])
  end

  defp insert_component(attrs) do
    Arca.Repo.insert_all("components", [attrs])
  end
end