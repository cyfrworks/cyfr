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
    with {:ok, resolved_ref} <- Compendium.Resolver.resolve_or_passthrough(ctx, reference) do
      case resolve_component(ctx, resolved_ref) do
        {:ok, component, ref} ->
          canonical_ref =
            Sanctum.ComponentRef.to_string(%Sanctum.ComponentRef{
              type: ref.type,
              namespace: ref.namespace,
              name: ref.name,
              version: ref.version
            })

          result =
            component
            |> Map.put("component_ref", canonical_ref)
            |> Map.put("type", ref.type)

          result =
            if resolved_ref != reference do
              Map.put(result, "resolved_from", reference)
            else
              result
            end

          {:ok, maybe_enrich_with_dependencies(ctx, component, result)}

        {:error, reason} ->
          {:error, reason}
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
          canonical_ref =
            Sanctum.ComponentRef.to_string(%Sanctum.ComponentRef{
              type: ref.type,
              namespace: ref.namespace,
              name: ref.name,
              version: ref.version
            })

          manifest = component[:manifest] || component["manifest"] || %{}
          manifest = decode_manifest(manifest)
          setup = manifest["setup"] || %{}

          secrets_status = check_secrets_status(ctx, canonical_ref, setup["secrets"] || [])
          oauth_status = check_oauth_status(ctx, canonical_ref, manifest["oauth"])
          {policy_effective, policy_source} = get_effective_policy_with_source(ctx, canonical_ref)
          deps = extract_dependency_refs(manifest)

          description =
            component[:description] || component["description"] || manifest["description"]

          configurable_fields =
            case Sanctum.Policy.FieldSchema.configurable_fields(setup["policy"]) do
              {:ok, fields} ->
                fields

              {:error, _} ->
                case Sanctum.Policy.FieldSchema.default_configurable_fields(ref.type) do
                  {:ok, fields} -> fields
                  {:error, _} -> nil
                end
            end

          # Tinctures use the policy system for rate_limit/timeout/is_public
          # (no host capabilities like allowed_domains). Policy-ready if setup.policy
          # is declared OR type is tincture (tincture fields are all optional).
          policy_ok = setup["policy"] != nil or ref.type in ~w(tincture)

          legacy_ready =
            all_configured?(secrets_status, policy_source, policy_ok) and
              oauth_ready?(oauth_status)

          # A component with a profile answers "ready" from its consent:
          # every bound need still live and digest-matching. The legacy
          # fields stay truthful beside it so the old setup surfaces
          # no-op rather than loop while both paths coexist.
          consent = Compendium.ConsentSetupPlan.section(ctx, canonical_ref)

          {:ok,
           %{
             component_ref: canonical_ref,
             description: description,
             type: ref.type,
             setup: setup,
             secrets: secrets_status,
             oauth: oauth_status,
             policy_recommended: setup["policy"],
             policy_current: policy_effective,
             policy_stored: policy_source in [:exact_ref, :name_level, :manifest_setup],
             configurable_fields: configurable_fields,
             dependencies: deps,
             consent: consent,
             ready: if(consent, do: consent.ready, else: legacy_ready)
           }}

        {:error, reason} ->
          {:error, reason}
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

              error ->
                error
            end
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

  # The secrets plane is retired: a legacy setup.secrets spec can no
  # longer be satisfied — the component declares needs and the operator
  # binds a Connection. Rows keep their shape so old surfaces render.
  defp check_secrets_status(_ctx, _canonical_ref, secret_specs) do
    Enum.map(secret_specs, fn spec ->
      %{
        name: spec["name"],
        description: spec["description"],
        required: spec["required"] || false,
        already_set: false,
        already_granted: false,
        warning: "the secrets plane is retired — declare needs and grant a Connection"
      }
    end)
  end

  defp get_effective_policy_with_source(ctx, canonical_ref) do
    case Sanctum.Policy.get_effective(ctx, canonical_ref) do
      {:ok, policy, meta} when is_struct(policy) ->
        {Map.from_struct(policy), meta[:source]}

      {:ok, policy, meta} when is_map(policy) ->
        {policy, meta[:source]}

      _ ->
        {nil, nil}
    end
  end

  defp all_configured?(secrets_status, policy_source, has_policy_requirements) do
    secrets_ready =
      Enum.all?(secrets_status, fn s ->
        !s.required || (s.already_set && s.already_granted)
      end)

    policy_ready =
      if has_policy_requirements do
        policy_source in [:exact_ref, :name_level, :manifest_setup]
      else
        true
      end

    secrets_ready && policy_ready
  end

  defp check_oauth_status(_ctx, _canonical_ref, nil), do: []
  defp check_oauth_status(_ctx, _canonical_ref, oauth) when not is_map(oauth), do: []

  defp check_oauth_status(ctx, _canonical_ref, oauth) do
    Enum.map(oauth, fn {provider, config} ->
      creds_configured = provider_creds_configured?(ctx, provider)

      %{
        provider: provider,
        scopes: config["scopes"] || [],
        provider_configured: creds_configured,
        # Component-keyed tokens are gone; authorization is a Connection
        # bound through the consent walk, reported by the consent section.
        component_authorized: false,
        ready: false
      }
    end)
  end

  defp provider_creds_configured?(ctx, provider) do
    case Sanctum.ProviderCredentials.configured?(ctx, provider) do
      true -> true
      _ -> false
    end
  end

  defp oauth_ready?([]), do: true
  defp oauth_ready?(oauth_status), do: Enum.all?(oauth_status, & &1.ready)

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
