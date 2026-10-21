# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.DependencyResolver do
  @moduledoc """
  Dependency resolution for CYFR components.

  Extracts static dependency declarations from component manifests,
  resolves the full dependency tree with cycle detection, and classifies
  dependency availability against the local registry.
  """

  alias Sanctum.Context

  @max_depth 10

  @doc """
  Extract static dependencies from a manifest map.

  The block's grammar is `Prima.Manifest.Dependencies`, which the consent
  blob reads too — a dependency a row records and an edge a consent
  carries are one parse.

  Returns `{:ok, [dep_map]}` or `{:error, reason}`.
  """
  @spec extract_from_manifest(map() | nil) :: {:ok, [map()]} | {:error, term()}
  def extract_from_manifest(manifest), do: Prima.Manifest.Dependencies.from_manifest(manifest)

  @doc """
  Resolve the full dependency tree for a component.

  Recursively resolves dependencies up to `@max_depth` levels deep,
  detecting and breaking cycles via a visited set.

  Returns `{:ok, tree}` where tree is a list of dependency nodes,
  each annotated with their own sub-dependencies. An installed dependency
  whose manifest the store cannot read or that does not decode fails the
  tree, `{:error, {:dependency_unreadable, ref, reason}}`, `ref` the
  dependency as its dependent declares it.
  """
  @spec resolve_tree(Context.t(), map()) :: {:ok, list()} | {:error, term()}
  def resolve_tree(%Context{} = ctx, manifest),
    do: do_resolve_tree(ctx, manifest, %{}, 0)

  defp do_resolve_tree(_ctx, _manifest, _visited, depth) when depth > @max_depth do
    {:ok, []}
  end

  defp do_resolve_tree(ctx, manifest, visited, depth) do
    with {:ok, deps} <- extract_from_manifest(manifest) do
      deps
      |> Enum.reduce_while({:ok, []}, fn dep, {:ok, nodes} ->
        case dep_node(ctx, dep, visited, depth) do
          {:ok, node} -> {:cont, {:ok, [node | nodes]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> then(fn
        {:ok, nodes} -> {:ok, Enum.reverse(nodes)}
        error -> error
      end)
    end
  end

  # `visited` is the refs on the path, a map of ref to true. A dependency
  # already on the path is a cycle and stops there; one not
  # installed has no children to read; one whose manifest or own
  # dependencies do not read fails the tree, since an unknown subtree is
  # not an empty one.
  defp dep_node(ctx, dep, visited, depth) do
    ref = dep.dependency_ref

    if Map.has_key?(visited, ref) do
      {:ok, dep |> Map.put(:cycle, true) |> Map.put(:children, [])}
    else
      with {:ok, children} <- children(ctx, dep, Map.put(visited, ref, true), depth),
           do: {:ok, dep |> Map.put(:cycle, false) |> Map.put(:children, children)}
    end
  end

  defp children(ctx, dep, visited, depth) do
    case resolve_dep_manifest(ctx, dep) do
      {:ok, child_manifest} ->
        do_resolve_tree(ctx, child_manifest, visited, depth + 1)

      {:error, :not_found} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:dependency_unreadable, dep.dependency_ref, reason}}
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
            if Map.get(dep, :optional) == true do
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

  def has_dynamic_deps?(manifest) when is_map(manifest),
    do: get_in(manifest, ["dependencies", "dynamic"]) != nil

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp check_dep_exists(ctx, %{
         dep_name: name,
         dep_version: version,
         dep_namespace: namespace,
         dep_type: component_type
       }) do
    if version == nil do
      # Versionless dep — check if any version exists
      case Arca.ComponentStorage.list_components(Sanctum.Context.actor(ctx),
             name: name,
             publisher: namespace,
             component_type: component_type
           ) do
        {:ok, [_ | _]} -> true
        _ -> false
      end
    else
      Arca.ComponentStorage.exists?(
        Sanctum.Context.actor(ctx),
        name,
        version,
        namespace,
        component_type
      )
    end
  end

  defp resolve_dep_manifest(ctx, %{
         dep_name: name,
         dep_version: version,
         dep_namespace: namespace,
         dep_type: component_type
       }) do
    result =
      if version == nil do
        # Versionless deps resolve through the registry's semver-aware
        # "latest" — the same pick the activation graph records — rather
        # than whatever row the adapter happens to return first.
        Compendium.Registry.latest_row(ctx, name, namespace, component_type)
      else
        Arca.ComponentStorage.get_component(
          Sanctum.Context.actor(ctx),
          name,
          version,
          namespace,
          component_type
        )
      end

    case result do
      {:ok, component} ->
        Prima.Manifest.decode_strict(component.manifest)

      {:error, _} = err ->
        err
    end
  end
end
