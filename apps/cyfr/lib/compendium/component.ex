# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Component do
  @moduledoc """
  Public API for component operations.

  Provides direct function calls for component inspection, blob retrieval,
  and setup plan generation — eliminating the MCP dispatch overhead for
  internal callers (e.g., the runtime's executor).
  """

  alias Sanctum.{Context, Refusals}
  alias Compendium.Registry

  require Logger

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

        # ONE key type on the way out. The registry row arrives atom-keyed
        # while the enrichment below adds string keys, so the row is
        # string-keyed first: every reader of the answer reads one key
        # shape (`["signature_verified"]` among them).
        result =
          component
          |> Map.new(fn {k, v} -> {to_string(k), v} end)
          |> Map.put("component_ref", canonical)
          |> Map.put("type", ref.type)

        result =
          if canonical != reference do
            Map.put(result, "resolved_from", reference)
          else
            result
          end

        if ref.type == Prima.AgentRef.type(),
          do: {:ok, result},
          else: maybe_enrich_with_dependencies(ctx, component, result)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get raw WASM bytes by content digest.

  Returns raw binary bytes (no base64 encoding).
  """
  @spec get_blob(Context.t(), String.t()) ::
          {:ok, binary()} | {:error, :blob_not_found | term()}
  def get_blob(%Context{} = ctx, digest) when is_binary(digest) do
    # Typed reasons stay typed until a wire renders them — flattening to
    # prose here left internal callers nothing to branch on.
    Registry.get_blob(ctx, digest)
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

        with {:ok, manifest} <- decode_manifest(component.manifest, canonical_ref),
             do: setup_plan(ctx, component, ref, canonical_ref, manifest)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp setup_plan(ctx, component, ref, canonical_ref, manifest) do
    needs = declared_needs(manifest)
    deps = extract_dependency_refs(manifest)

    description = component.description || manifest["description"]

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
  end

  # ============================================================================
  # Component Resolution — the one owner
  # ============================================================================

  @doc """
  Resolve a component reference string into its registry row and a ref map
  carrying the actually-resolved version — one registry lookup, whether
  the ref is pinned (`Registry.get/5`) or versionless
  (`Registry.get_latest/4`, whose row already carries the manifest).
  A component the registry does not hold is
  `{:error, {:not_found, {:component, reference}}}`; a malformed reference
  or a storage fault is a human-readable `{:error, binary}`. Nothing
  raises.

  The one resolver: the MCP tool modules delegate here
  (`Compendium.Providers.Shared`) and `Compendium.Resolver` is its
  string-in adapter, so no caller and no surface can drift.
  """
  @spec resolve_component(Context.t(), term()) ::
          {:ok, map(), map()}
          | {:error, {:not_found, {:component, String.t()}} | String.t()}
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
            {:ok, component,
             %{namespace: namespace, name: name, version: component.version, type: type}}

          {:error, :not_found} ->
            {:error, {:not_found, {:component, reference}}}

          {:error, reason} ->
            {:error, "Failed to resolve component #{reference}: #{Refusals.render(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Parse a component reference — canonical (`type:namespace.name:version`)
  # or the flexible short forms (`c:local.tool`) — into
  # `{:ok, namespace, name, version, type}` for registry lookup. The one
  # grammar for every resolver (`Prima.ComponentRef.normalize_flexible/1`,
  # fields validated); the namespace doubles as the publisher filter, and
  # version may be nil.
  @spec parse_reference(term()) ::
          {:ok, String.t(), String.t(), String.t() | nil, String.t() | nil}
          | {:error, String.t()}
  defp parse_reference(reference) when is_binary(reference) do
    case Prima.ComponentRef.normalize_flexible(reference) do
      {:ok, %Prima.ComponentRef{type: type, namespace: namespace, name: name, version: version}} ->
        {:ok, namespace, name, version, type}

      {:error, reason} ->
        {:error, "Invalid reference format: #{reference}. #{reason}"}
    end
  end

  defp parse_reference(_), do: {:error, "Reference must be a string"}

  defp canonical_ref(ref) do
    Prima.ComponentRef.to_string(%Prima.ComponentRef{
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
    with {:ok, manifest} <- decode_manifest(component.manifest, result["component_ref"]),
         do: {:ok, enrich_with_dependencies(ctx, manifest, result)}
  end

  defp enrich_with_dependencies(ctx, manifest, result) do
    static_deps = get_in(manifest, ["dependencies", "static"]) || []
    has_dynamic = Compendium.DependencyResolver.has_dynamic_deps?(manifest)

    if static_deps == [] and not has_dynamic do
      result
    else
      case Compendium.DependencyResolver.resolve_tree(ctx, manifest) do
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

  # A stored manifest that does not decode is damage: the read refuses it
  # rather than read a component that declares nothing. The line names the
  # component, never the manifest's bytes.
  defp decode_manifest(value, ref) do
    case Prima.Manifest.decode_strict(value) do
      {:ok, manifest} ->
        {:ok, manifest}

      {:error, :malformed_manifest} ->
        Logger.warning("[Compendium.Component] manifest malformed: #{ref}")
        {:error, {:corrupt, {:manifest, ref}}}
    end
  end

  # ============================================================================
  # Private — Setup Plan Helpers
  # ============================================================================

  defp declared_needs(manifest) do
    Prima.Manifest.Needs.from_manifest(manifest) || []
  end

  # The decoded manifest's `dependencies.static` entries: a ref string, or
  # an object naming its ref (`Prima.Manifest`'s grammar).
  defp extract_dependency_refs(manifest) do
    manifest
    |> get_in(["dependencies", "static"])
    |> List.wrap()
    |> Enum.map(fn
      dep when is_binary(dep) ->
        %{ref: dep, optional: false, reason: nil}

      dep ->
        %{ref: dep["ref"], optional: dep["optional"] || false, reason: dep["reason"]}
    end)
  end
end
