# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.MCP.Shared do
  @moduledoc """
  Helpers shared across the Compendium MCP tool modules
  (`Compendium.MCP` facade, `ComponentTool`, `AquaTool`, `RegistryTool`).

  These are moved verbatim from the original `Compendium.MCP` module to
  preserve behaviour exactly; only their visibility changed from `defp`
  to `def` so the tool modules can call them.
  """

  alias Sanctum.Context
  alias Compendium.Registry

  # Resolves a component reference string into a component map and a ref map
  # with the actual resolved version. When the parsed version is nil
  # (e.g., bare name without version), resolves to the most recent published
  # version via Registry.get_latest/4.
  def resolve_component(ctx, reference) do
    case parse_reference(reference) do
      {:ok, namespace, name, version, type} ->
        result =
          if version == nil do
            # get_latest uses list action which omits manifest; resolve version
            # then re-fetch with get to include manifest
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
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Parse a component reference using the canonical format (type:namespace.name:version).
  # Returns {:ok, namespace, name, version, type} for database lookup.
  # The namespace is used as the publisher filter for disambiguation.
  # The type may be nil when not specified in the ref.
  def parse_reference(reference) when is_binary(reference) do
    case Sanctum.ComponentRef.parse(reference) do
      {:ok, %Sanctum.ComponentRef{type: type, namespace: namespace, name: name, version: version}} ->
        {:ok, namespace, name, version, type}

      {:error, reason} ->
        {:error, "Invalid reference format: #{reference}. #{reason}"}
    end
  end

  def parse_reference(_), do: {:error, "Reference must be a string"}

  # Canonical formatter shared with Compendium.OCI.Client (oci/client.ex:101-103).
  # Errors.to_string/1 produces "Policy acceptance required on cyfr.run
  # (HTTP 412, policy_acceptance_required)" — readable for TUI / toast surfaces;
  # actionable_hint/1 appends a remediation suffix when one is defined for the
  # reason. Verbose `detail` stays out of user-facing output (it's logged via
  # Errors.to_log_string/1 inside the client).
  def to_error_string(%Compendium.OCI.Errors{} = err) do
    msg = Compendium.OCI.Errors.to_string(err)
    hint = Compendium.OCI.Errors.actionable_hint(err)
    if hint != "", do: "#{msg}. #{hint}", else: msg
  end

  def to_error_string(err) when is_binary(err), do: err
  def to_error_string(err), do: inspect(err)

  # Find a bearer scoped to a specific namespace.
  def namespace_bearer(%Context{user_id: user_id}, slug)
      when is_binary(user_id) and user_id != "" and is_binary(slug) do
    registry = Compendium.Registry.canonical_host()

    case Compendium.Registry.CredentialStore.get(user_id, registry, slug) do
      {:ok, %{type: :push_token, token: token}} when is_binary(token) ->
        {:ok, token}

      _ ->
        {:error, "no push token for namespace '#{slug}' — run `cyfr login`"}
    end
  end

  def namespace_bearer(_, _), do: {:error, "authentication required"}

  # deprecate/yank require a fully-qualified ref (all four fields).
  # Sanctum.ComponentRef.parse/1 can succeed with version=nil for
  # `c:alice.foo` (latest); these actions must target a specific version.
  def ensure_fully_qualified(%Sanctum.ComponentRef{version: nil}),
    do: {:error, "deprecate/yank require a pinned version, e.g. c:alice.foo:1.0.0"}

  def ensure_fully_qualified(%Sanctum.ComponentRef{version: ""}),
    do: {:error, "deprecate/yank require a pinned version, e.g. c:alice.foo:1.0.0"}

  def ensure_fully_qualified(%Sanctum.ComponentRef{}), do: :ok
end
