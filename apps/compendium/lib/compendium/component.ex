defmodule Compendium.Component do
  @moduledoc """
  Public API for component operations.

  Provides direct function calls for component inspection, blob retrieval,
  and setup plan generation — eliminating the MCP dispatch overhead for
  internal callers (e.g., Opus executor).
  """

  require Logger

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

  Core edition falls back to cyfr.run when not found locally.
  """
  @spec inspect_component(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def inspect_component(%Context{} = ctx, reference) when is_binary(reference) do
    with {:ok, resolved_ref} <- Compendium.Resolver.resolve_or_passthrough(ctx, reference) do
      case resolve_component(ctx, resolved_ref) do
        {:ok, component, ref} ->
          canonical_ref = Sanctum.ComponentRef.to_string(%Sanctum.ComponentRef{
            type: ref.type,
            namespace: ref.namespace,
            name: ref.name,
            version: ref.version
          })

          result = component
            |> Map.put("component_ref", canonical_ref)
            |> Map.put("type", ref.type)

          result =
            if resolved_ref != reference do
              Map.put(result, "resolved_from", reference)
            else
              result
            end

          {:ok, maybe_enrich_with_dependencies(ctx, component, result)}

        {:error, _reason} ->
          if Compendium.Edition.core_edition?() do
            inspect_cyfr_run_fallback(ctx, reference)
          else
            {:error, "Component not found: #{reference}"}
          end
      end
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

  Returns a map with secrets status, policy status, dependencies,
  and overall readiness.
  """
  @spec setup_plan(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def setup_plan(%Context{} = ctx, reference) when is_binary(reference) do
    with {:ok, resolved_ref} <- Compendium.Resolver.resolve_or_passthrough(ctx, reference) do
      case resolve_component(ctx, resolved_ref) do
        {:ok, component, ref} ->
          canonical_ref = Sanctum.ComponentRef.to_string(%Sanctum.ComponentRef{
            type: ref.type, namespace: ref.namespace,
            name: ref.name, version: ref.version
          })
          manifest = component[:manifest] || component["manifest"] || %{}
          manifest = decode_manifest(manifest)
          setup = manifest["setup"] || %{}

          secrets_status = check_secrets_status(ctx, canonical_ref, setup["secrets"] || [])
          policy_status = check_policy_status(ctx, canonical_ref)
          policy_effective = get_effective_policy(ctx, canonical_ref)
          deps = extract_dependency_refs(manifest)
          description = component[:description] || component["description"] || manifest["description"]

          configurable_fields =
            case Sanctum.Policy.FieldSchema.configurable_fields(setup["policy"]) do
              {:ok, fields} -> fields
              {:error, _} ->
                case Sanctum.Policy.FieldSchema.default_configurable_fields(ref.type) do
                  {:ok, fields} -> fields
                  {:error, _} -> nil
                end
            end

          {:ok, %{
            component_ref: canonical_ref,
            description: description,
            type: ref.type,
            setup: setup,
            secrets: secrets_status,
            policy_recommended: setup["policy"],
            policy_current: policy_effective || policy_status,
            policy_stored: policy_status != nil,
            configurable_fields: configurable_fields,
            dependencies: deps,
            ready: all_configured?(secrets_status, policy_status)
          }}

        {:error, reason} -> {:error, reason}
      end
    end
  end

  # ============================================================================
  # Private — Component Resolution
  # ============================================================================

  defp resolve_component(ctx, reference) do
    case parse_reference(reference) do
      {:ok, namespace, name, version, type} ->
        result =
          if version == nil do
            case Registry.get_latest(ctx, name, namespace, type) do
              {:ok, component} ->
                resolved_version = component[:version]
                if resolved_version do
                  Registry.get(ctx, name, resolved_version, namespace, type)
                else
                  {:ok, component}
                end
              error -> error
            end
          else
            Registry.get(ctx, name, version, namespace, type)
          end

        case result do
          {:ok, component} ->
            resolved_version = component[:version] || version
            resolved_type = type || component[:component_type] || component[:type]
            {:ok, component, %{namespace: namespace, name: name, version: resolved_version, type: resolved_type}}

          {:error, :not_found} ->
            {:error, "Component not found: #{reference}"}

          {:error, reason} ->
            {:error, "Failed to resolve component #{reference}: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_reference(reference) when is_binary(reference) do
    case Sanctum.ComponentRef.parse(reference) do
      {:ok, %Sanctum.ComponentRef{type: type, namespace: namespace, name: name, version: version}} ->
        {:ok, namespace, name, version, type}

      {:error, reason} ->
        {:error, "Invalid reference format: #{reference}. #{reason}"}
    end
  end

  defp parse_reference(_), do: {:error, "Reference must be a string"}

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
          |> Map.put("optional_missing", Enum.map(availability.optional_missing, & &1[:dependency_ref]))

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
  # Private — cyfr.run Fallback (Core edition only)
  # ============================================================================

  defp inspect_cyfr_run_fallback(ctx, reference) do
    case parse_reference(reference) do
      {:ok, namespace, name, version, type} ->
        component_type = type || (
          Logger.warning("[Compendium.Component] No component type specified for #{reference}, defaulting to \"reagent\". " <>
                         "Specify type in the reference (e.g., catalyst:#{reference}) for accurate results.")
          "reagent"
        )

        case Compendium.CyfrRun.Client.get_component(ctx, component_type, namespace, name, version) do
          {:ok, component} ->
            canonical_ref = Sanctum.ComponentRef.to_string(%Sanctum.ComponentRef{
              type: component_type,
              namespace: namespace,
              name: name,
              version: component["version"] || version
            })

            {:ok, component
              |> Map.put("component_ref", canonical_ref)
              |> Map.put("type", component_type)
              |> Map.put("source", "cyfr.run")
              |> Map.put("note", "Component found on cyfr.run but not locally. " <>
                                 "Run `component pull #{reference}` to download it.")}

          {:error, err} ->
            Logger.error("[Compendium.Component] Inspect fallback to cyfr.run failed for #{reference}: #{inspect(err)}")
            {:error, "Component not found locally or on cyfr.run: #{reference}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Private — Setup Plan Helpers
  # ============================================================================

  defp check_secrets_status(ctx, canonical_ref, secret_specs) do
    {existing_secrets, secrets_error} = case Sanctum.Secrets.list(ctx) do
      {:ok, names} -> {MapSet.new(names), nil}
      other ->
        Logger.warning("[Compendium.Component] Failed to list secrets: #{inspect(other)}")
        {MapSet.new(), "Unable to check secret status (Sanctum unavailable)"}
    end

    {granted_secrets, grants_error} = case Sanctum.Secrets.resolve_granted_secrets(ctx, canonical_ref) do
      {:ok, %{secrets: secrets}} when is_map(secrets) -> {MapSet.new(Map.keys(secrets)), nil}
      other ->
        Logger.warning("[Compendium.Component] Failed to resolve granted secrets for #{canonical_ref}: #{inspect(other)}")
        {MapSet.new(), "Unable to check grant status (Sanctum unavailable)"}
    end

    warning = secrets_error || grants_error

    Enum.map(secret_specs, fn spec ->
      name = spec["name"]
      entry = %{
        name: name,
        description: spec["description"],
        required: spec["required"] || false,
        already_set: MapSet.member?(existing_secrets, name),
        already_granted: MapSet.member?(granted_secrets, name)
      }
      if warning, do: Map.put(entry, :warning, warning), else: entry
    end)
  end

  defp check_policy_status(_ctx, canonical_ref) do
    case Sanctum.PolicyStore.get(canonical_ref) do
      {:ok, policy} when is_struct(policy) -> Map.from_struct(policy)
      {:ok, policy} when is_map(policy) -> policy
      _ -> nil
    end
  end

  defp get_effective_policy(ctx, canonical_ref) do
    case Sanctum.Policy.get_effective(ctx, canonical_ref) do
      {:ok, policy, _meta} when is_struct(policy) -> Map.from_struct(policy)
      {:ok, policy, _meta} when is_map(policy) -> policy
      _ -> nil
    end
  end

  defp all_configured?(secrets_status, policy_status) do
    secrets_ready = Enum.all?(secrets_status, fn s ->
      !s.required || (s.already_set && s.already_granted)
    end)

    secrets_ready && policy_status != nil
  end

  defp extract_dependency_refs(component) do
    deps = component["dependencies"] || component[:dependencies] || %{}
    static = deps["static"] || deps[:static] || []

    Enum.map(static, fn dep ->
      %{
        ref: dep["ref"] || dep[:ref],
        optional: dep["optional"] || dep[:optional] || false,
        reason: dep["reason"] || dep[:reason]
      }
    end)
  end
end
