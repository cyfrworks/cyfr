defmodule Compendium.DependencyResolver do
  @moduledoc """
  Dependency resolution for CYFR components.

  Extracts static dependency declarations from component manifests,
  resolves the full dependency tree with cycle detection, and classifies
  dependency availability against the local registry.
  """

  require Logger

  alias Sanctum.Context

  @max_depth 10

  @doc """
  Extract static dependencies from a manifest map.

  Parses `dependencies.static` entries, validates each ref via
  `Sanctum.ComponentRef.parse/1`, and returns a list of dependency maps
  ready for storage.

  Returns `{:ok, [dep_map]}` or `{:error, reason}`.
  """
  @spec extract_from_manifest(map(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def extract_from_manifest(manifest, component_id)
      when is_map(manifest) and is_binary(component_id) do
    case get_in(manifest, ["dependencies", "static"]) ||
           get_in(manifest, [:dependencies, :static]) do
      nil ->
        {:ok, []}

      static when is_list(static) ->
        deps =
          Enum.reduce_while(static, {:ok, []}, fn entry, {:ok, acc} ->
            ref_str =
              if is_binary(entry), do: entry, else: entry["ref"] || entry[:ref]

            {optional, reason} =
              if is_binary(entry) do
                {0, nil}
              else
                {if((entry["optional"] || entry[:optional]) == true, do: 1, else: 0),
                 entry["reason"] || entry[:reason]}
              end

            case Sanctum.ComponentRef.parse(ref_str) do
              {:ok, parsed} ->
                dep = %{
                  dependency_ref: ref_str,
                  dep_type: parsed.type,
                  dep_namespace: parsed.namespace,
                  dep_name: parsed.name,
                  dep_version: parsed.version,
                  optional: optional,
                  reason: reason
                }

                {:cont, {:ok, [dep | acc]}}

              {:error, reason} ->
                {:halt, {:error, "Invalid dependency ref '#{ref_str}': #{reason}"}}
            end
          end)

        case deps do
          {:ok, list} -> {:ok, Enum.reverse(list)}
          {:error, _} = err -> err
        end

      _ ->
        {:ok, []}
    end
  end

  def extract_from_manifest(nil, _component_id), do: {:ok, []}

  @doc """
  Resolve the full dependency tree for a component.

  Recursively resolves dependencies up to `@max_depth` levels deep,
  detecting and breaking cycles via a visited set.

  Returns `{:ok, tree}` where tree is a list of dependency nodes,
  each annotated with their own sub-dependencies.
  """
  @spec resolve_tree(Context.t(), String.t(), map()) :: {:ok, list()} | {:error, term()}
  def resolve_tree(%Context{} = ctx, component_id, manifest) do
    do_resolve_tree(ctx, component_id, manifest, MapSet.new(), 0)
  end

  defp do_resolve_tree(_ctx, _component_id, _manifest, _visited, depth) when depth > @max_depth do
    {:ok, []}
  end

  defp do_resolve_tree(ctx, component_id, manifest, visited, depth) do
    case extract_from_manifest(manifest, component_id) do
      {:ok, []} ->
        {:ok, []}

      {:ok, deps} ->
        nodes =
          Enum.map(deps, fn dep ->
            ref = dep.dependency_ref

            if MapSet.member?(visited, ref) do
              # Cycle detected — mark and stop recursion
              Map.put(dep, :cycle, true)
              |> Map.put(:children, [])
            else
              new_visited = MapSet.put(visited, ref)

              # Try to find this dependency in the local registry and recurse
              children =
                case resolve_dep_manifest(ctx, dep) do
                  {:ok, child_id, child_manifest} ->
                    case do_resolve_tree(ctx, child_id, child_manifest, new_visited, depth + 1) do
                      {:ok, child_deps} -> child_deps
                      {:error, _} -> []
                    end

                  {:error, _} ->
                    []
                end

              dep
              |> Map.put(:cycle, false)
              |> Map.put(:children, children)
            end
          end)

        {:ok, nodes}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Classify the availability of dependencies against the local registry.

  Returns a map with:
  - `:present` — deps that are available locally (exact version match)
  - `:missing` — required deps that are missing
  - `:optional_missing` — optional deps that are missing
  - `:all_satisfied` — boolean, true if no required deps are missing
  """
  @spec classify_availability(Context.t(), [map()]) :: map()
  def classify_availability(%Context{} = ctx, deps) when is_list(deps) do
    {present, missing, optional_missing} =
      Enum.reduce(deps, {[], [], []}, fn dep, {p, m, o} ->
        case check_dep_exists(ctx, dep) do
          true ->
            {[dep | p], m, o}

          false ->
            if dep[:optional] == 1 or dep["optional"] == 1 do
              {p, m, [dep | o]}
            else
              {p, [dep | m], o}
            end
        end
      end)

    %{
      present: Enum.reverse(present),
      missing: Enum.reverse(missing),
      optional_missing: Enum.reverse(optional_missing),
      all_satisfied: missing == []
    }
  end

  @doc """
  Check if a manifest declares any dynamic dependencies.
  """
  @spec has_dynamic_deps?(map() | nil) :: boolean()
  def has_dynamic_deps?(nil), do: false

  def has_dynamic_deps?(manifest) when is_map(manifest) do
    dynamic =
      get_in(manifest, ["dependencies", "dynamic"]) || get_in(manifest, [:dependencies, :dynamic])

    dynamic != nil
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp check_dep_exists(ctx, dep) do
    name = dep[:dep_name] || dep["dep_name"]
    version = dep[:dep_version] || dep["dep_version"]
    namespace = dep[:dep_namespace] || dep["dep_namespace"]
    component_type = dep[:dep_type] || dep["dep_type"]

    if version == nil do
      # Versionless dep — check if any version exists
      case Arca.ComponentStorage.list_components(ctx,
             name: name,
             publisher: namespace,
             component_type: component_type
           ) do
        {:ok, [_ | _]} -> true
        _ -> false
      end
    else
      Arca.ComponentStorage.exists?(ctx, name, version, namespace, component_type)
    end
  end

  defp resolve_dep_manifest(ctx, dep) do
    name = dep[:dep_name] || dep["dep_name"]
    version = dep[:dep_version] || dep["dep_version"]
    namespace = dep[:dep_namespace] || dep["dep_namespace"]
    component_type = dep[:dep_type] || dep["dep_type"]

    result =
      if version == nil do
        case Arca.ComponentStorage.list_components(ctx,
               name: name,
               publisher: namespace,
               component_type: component_type
             ) do
          {:ok, [latest | _]} -> {:ok, latest}
          {:ok, []} -> {:error, :not_found}
          error -> error
        end
      else
        Arca.ComponentStorage.get_component(ctx, name, version, namespace, component_type)
      end

    case result do
      {:ok, component} ->
        manifest = Compendium.Manifest.decode(component[:manifest])
        {:ok, component[:id], manifest}

      {:error, _} = err ->
        err
    end
  end
end
