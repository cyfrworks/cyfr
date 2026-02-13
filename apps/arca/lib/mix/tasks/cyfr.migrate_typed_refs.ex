defmodule Mix.Tasks.Cyfr.MigrateTypedRefs do
  @moduledoc """
  Migrate stored component refs to include the type prefix.

  Scans the `policies`, `secret_grants`, and `component_configs` tables for
  `component_ref` values that lack a type prefix, looks up the component in the
  `components` table to determine its type, and rewrites the stored ref to
  `"type:namespace.name:version"`.

  Refs that already have a type prefix are skipped (idempotent).

  ## Usage

      mix cyfr.migrate_typed_refs          # preview changes (dry run)
      mix cyfr.migrate_typed_refs --apply  # apply changes

  """
  use Mix.Task

  import Ecto.Query

  @shortdoc "Add type prefix to stored component refs in policies, grants, and configs"

  @impl Mix.Task
  def run(args) do
    apply? = "--apply" in args

    Mix.Task.run("app.start")

    # Build a lookup map: "namespace.name:version" => component_type
    type_lookup = build_type_lookup()
    Mix.shell().info("Built type lookup for #{map_size(type_lookup)} component(s).\n")

    policy_changes = scan_policies(type_lookup)
    grant_changes = scan_secret_grants(type_lookup)
    config_changes = scan_component_configs(type_lookup)

    total = length(policy_changes) + length(grant_changes) + length(config_changes)

    if total == 0 do
      Mix.shell().info("All stored refs already have type prefixes. Nothing to do.")
    else
      print_changes("policies", policy_changes)
      print_changes("secret_grants", grant_changes)
      print_changes("component_configs", config_changes)

      Mix.shell().info("Total: #{total} ref(s) to migrate.\n")

      if apply? do
        Mix.shell().info("Applying changes...")

        Arca.Repo.transaction(fn ->
          apply_policy_changes(policy_changes)
          apply_grant_changes(grant_changes)
          apply_config_changes(config_changes)
        end)
        |> case do
          {:ok, _} ->
            Mix.shell().info("Successfully migrated #{total} ref(s).")

          {:error, reason} ->
            Mix.shell().error("Transaction failed: #{inspect(reason)}")
        end
      else
        Mix.shell().info("Dry run — pass --apply to commit these changes.")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Type Lookup
  # ---------------------------------------------------------------------------

  defp build_type_lookup do
    from(c in "components",
      select: %{
        name: c.name,
        version: c.version,
        component_type: c.component_type,
        publisher: c.publisher
      }
    )
    |> Arca.Repo.all()
    |> Enum.reduce(%{}, fn comp, acc ->
      publisher = comp.publisher || "local"
      ref_key = "#{publisher}.#{comp.name}:#{comp.version}"
      Map.put(acc, ref_key, comp.component_type)
    end)
  rescue
    _ -> %{}
  end

  # ---------------------------------------------------------------------------
  # Scanning
  # ---------------------------------------------------------------------------

  defp scan_policies(type_lookup) do
    from(p in "policies", select: %{id: p.id, component_ref: p.component_ref})
    |> Arca.Repo.all()
    |> Enum.flat_map(fn row ->
      case maybe_add_type(row.component_ref, type_lookup) do
        {:changed, new_ref} -> [{row.id, row.component_ref, new_ref}]
        :unchanged -> []
      end
    end)
  rescue
    _ -> []
  end

  defp scan_secret_grants(type_lookup) do
    from(g in "secret_grants", select: %{id: g.id, component_ref: g.component_ref})
    |> Arca.Repo.all()
    |> Enum.flat_map(fn row ->
      case maybe_add_type(row.component_ref, type_lookup) do
        {:changed, new_ref} -> [{row.id, row.component_ref, new_ref}]
        :unchanged -> []
      end
    end)
  rescue
    _ -> []
  end

  defp scan_component_configs(type_lookup) do
    from(c in "component_configs", select: %{id: c.id, component_ref: c.component_ref})
    |> Arca.Repo.all()
    |> Enum.flat_map(fn row ->
      case maybe_add_type(row.component_ref, type_lookup) do
        {:changed, new_ref} -> [{row.id, row.component_ref, new_ref}]
        :unchanged -> []
      end
    end)
  rescue
    _ -> []
  end

  # ---------------------------------------------------------------------------
  # Ref Rewriting
  # ---------------------------------------------------------------------------

  @known_types ~w(catalyst reagent formula)
  @type_shorthands ~w(c r f)

  defp maybe_add_type(ref, type_lookup) do
    if has_type_prefix?(ref) do
      :unchanged
    else
      case Map.get(type_lookup, ref) do
        nil -> :unchanged
        type -> {:changed, "#{type}:#{ref}"}
      end
    end
  end

  defp has_type_prefix?(ref) do
    case String.split(ref, ":", parts: 2) do
      [first, _rest] ->
        not String.contains?(first, ".") and
          (first in @known_types or first in @type_shorthands)
      _ ->
        false
    end
  end

  # ---------------------------------------------------------------------------
  # Applying Changes
  # ---------------------------------------------------------------------------

  defp apply_policy_changes(changes) do
    for {id, _old_ref, new_ref} <- changes do
      from(p in "policies", where: p.id == ^id)
      |> Arca.Repo.update_all(set: [component_ref: new_ref])
    end
  end

  defp apply_grant_changes(changes) do
    for {id, _old_ref, new_ref} <- changes do
      from(g in "secret_grants", where: g.id == ^id)
      |> Arca.Repo.update_all(set: [component_ref: new_ref])
    end
  end

  defp apply_config_changes(changes) do
    for {id, _old_ref, new_ref} <- changes do
      from(c in "component_configs", where: c.id == ^id)
      |> Arca.Repo.update_all(set: [component_ref: new_ref])
    end
  end

  # ---------------------------------------------------------------------------
  # Output
  # ---------------------------------------------------------------------------

  defp print_changes(_table, []), do: :ok

  defp print_changes(table, changes) do
    Mix.shell().info("#{table} (#{length(changes)} change(s)):")

    for {_id, old_ref, new_ref} <- changes do
      Mix.shell().info("  #{old_ref} -> #{new_ref}")
    end

    Mix.shell().info("")
  end
end
