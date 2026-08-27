# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Component do
  @moduledoc """
  Public API for component operations.

  Provides direct function calls for component inspection, blob retrieval,
  and setup plan generation — eliminating the MCP dispatch overhead for
  internal callers (e.g., Opus executor).
  """

  alias Sanctum.Context
  alias Compendium.Registry

  @doc """
  Inspect a component by reference.

  Resolves the reference, fetches component metadata, builds the canonical
  component_ref, and enriches with dependency information.

  Returns `{:ok, component_map}` where the map includes:
  - `"component_ref"` — canonical reference string
  - `"type"` — component type
  - `"resolved_from"` — original reference if it was resolved (e.g., versionless)
  - dependency info when applicable

  """
  @spec inspect_component(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def inspect_component(%Context{} = ctx, reference) when is_binary(reference) do
    case resolve_component(ctx, reference) do
      {:ok, component, ref} ->
        canonical = canonical_ref(ref)

        result =
          component
          |> Map.put("component_ref", canonical)
          |> Map.put("type", ref.type)

        result =
          if canonical != reference do
            Map.put(result, "resolved_from", reference)
          else
            result
          end

        {:ok, maybe_enrich_with_dependencies(ctx, component, result)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get raw WASM bytes by content digest.

  Returns raw binary bytes (no base64 encoding).
  """
  @spec get_blob(Context.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def get_blob(%Context{} = ctx, digest) when is_binary(digest) do
    case Registry.get_blob(ctx, digest) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :blob_not_found} -> {:error, "Blob not found for digest: #{digest}"}
      {:error, reason} -> {:error, "Failed to get blob: #{inspect(reason)}"}
    end
  end

  @doc """
  Generate a setup plan for a component.

  Returns the component's declared needs, its dependencies, the consent
  section (when a profile exists), and overall readiness.
  """
  @spec setup_plan(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def setup_plan(%Context{} = ctx, reference) when is_binary(reference) do
    case resolve_component(ctx, reference) do
      {:ok, component, ref} ->
        canonical_ref = canonical_ref(ref)

        manifest = component[:manifest] || component["manifest"] || %{}
        manifest = decode_manifest(manifest)

        needs = declared_needs(manifest)
        deps = extract_dependency_refs(manifest)

        description =
          component[:description] || component["description"] || manifest["description"]

        # A component with a profile answers "ready" from its consent:
        # every bound need still live and digest-matching. Without a
        # profile, only a component that requires nothing reads ready —
        # anything with a required need is waiting on the consent walk.
        consent = Compendium.ConsentSetupPlan.section(ctx, canonical_ref)

        ready =
          case consent do
            nil -> not Enum.any?(needs, & &1.required)
            consent -> consent.ready
          end

        {:ok,
         %{
           component_ref: canonical_ref,
           description: description,
           type: ref.type,
           needs: needs,
           dependencies: deps,
           consent: consent,
           ready: ready
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Component Resolution — the one owner
  # ============================================================================

  @doc """
  Resolve a component reference string into its registry row and a ref map
  carrying the actually-resolved version — one registry lookup, whether
  the ref is pinned (`Registry.get/5`) or versionless
  (`Registry.get_latest/4`, whose row already carries the manifest).
  Every error — malformed reference, not found, storage fault — is a
  human-readable `{:error, binary}`, never a raise.

  The one resolver: the MCP tool modules delegate here
  (`Compendium.MCP.Shared`) and `Compendium.Resolver` is its
  string-in/string-out adapter, so no caller and no surface can drift.
  """
  @spec resolve_component(Context.t(), term()) :: {:ok, map(), map()} | {:error, String.t()}
  def resolve_component(%Context{} = ctx, reference) do
    case parse_reference(reference) do
      {:ok, namespace, name, version, type} ->
        # One lookup either way: `get_latest/4` reads full rows (manifest
        # included), so a versionless ref needs no re-fetch.
        result =
          if version == nil do
            Registry.get_latest(ctx, name, namespace, type)
          else
            Registry.get(ctx, name, version, namespace, type)
          end

        case result do
          {:ok, component} ->
            resolved_version = component[:version] || version
            resolved_type = type || component[:component_type] || component[:type]

            {:ok, component,
             %{namespace: namespace, name: name, version: resolved_version, type: resolved_type}}

          {:error, :not_found} ->
            {:error, "Component not found: #{reference}"}

          {:error, reason} ->
            {:error, "Failed to resolve component #{reference}: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parse a component reference — canonical (`type:namespace.name:version`)
  or the flexible short forms (`c:local.tool`) — into
  `{:ok, namespace, name, version, type}` for registry lookup. The one
  grammar for every resolver (`Sanctum.ComponentRef.normalize_flexible/1`,
  fields validated); the namespace doubles as the publisher filter, and
  version may be nil.
  """
  @spec parse_reference(term()) ::
          {:ok, String.t(), String.t(), String.t() | nil, String.t() | nil}
          | {:error, String.t()}
  def parse_reference(reference) when is_binary(reference) do
    case Sanctum.ComponentRef.normalize_flexible(reference) do
      {:ok, %Sanctum.ComponentRef{type: type, namespace: namespace, name: name, version: version}} ->
        {:ok, namespace, name, version, type}

      {:error, reason} ->
        {:error, "Invalid reference format: #{reference}. #{reason}"}
    end
  end

  def parse_reference(_), do: {:error, "Reference must be a string"}

  defp canonical_ref(ref) do
    Sanctum.ComponentRef.to_string(%Sanctum.ComponentRef{
      type: ref.type,
      namespace: ref.namespace,
      name: ref.name,
      version: ref.version
    })
  end

  # ============================================================================
  # Private — Dependency Enrichment
  # ============================================================================

  defp maybe_enrich_with_dependencies(ctx, component, result) do
    manifest = decode_manifest(component[:manifest] || component["manifest"])

    static_deps = get_in(manifest, ["dependencies", "static"]) || []
    has_dynamic = Compendium.DependencyResolver.has_dynamic_deps?(manifest)

    if static_deps == [] and not has_dynamic do
      result
    else
      component_id = component[:id] || component["id"]

      case Compendium.DependencyResolver.resolve_tree(ctx, component_id, manifest) do
        {:ok, tree} ->
          flat_deps = flatten_dep_tree(tree)
          availability = Compendium.DependencyResolver.classify_availability(ctx, flat_deps)

          result
          |> Map.put("dependencies", tree)
          |> Map.put("has_dynamic", has_dynamic)
          |> Map.put("all_satisfied", availability.all_satisfied)
          |> Map.put("missing", Enum.map(availability.missing, & &1[:dependency_ref]))
          |> Map.put(
            "optional_missing",
            Enum.map(availability.optional_missing, & &1[:dependency_ref])
          )

        {:error, _reason} ->
          result
      end
    end
  end

  defp flatten_dep_tree(tree) when is_list(tree) do
    Enum.flat_map(tree, fn node ->
      children = Map.get(node, :children, [])
      base = Map.drop(node, [:children, :cycle])
      [base | flatten_dep_tree(children)]
    end)
  end

  defdelegate decode_manifest(value), to: Compendium.Manifest, as: :decode

  # ============================================================================
  # Private — Setup Plan Helpers
  # ============================================================================

  defp declared_needs(manifest) do
    Compendium.Manifest.Needs.from_manifest(manifest) || []
  end

  defp extract_dependency_refs(component) do
    deps = component["dependencies"] || component[:dependencies] || %{}
    static = deps["static"] || deps[:static] || []

    Enum.map(static, fn
      dep when is_binary(dep) ->
        %{ref: dep, optional: false, reason: nil}

      dep ->
        %{
          ref: dep["ref"] || dep[:ref],
          optional: dep["optional"] || dep[:optional] || false,
          reason: dep["reason"] || dep[:reason]
        }
    end)
  end
end
