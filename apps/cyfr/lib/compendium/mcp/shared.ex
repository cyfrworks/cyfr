# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.MCP.Shared do
  @moduledoc """
  Helpers shared across the Compendium MCP tool modules
  (`Compendium.MCP` facade, `ComponentTool`, `AquaTool`, `RegistryTool`).

  Component resolution delegates to `Compendium.Component` — the one
  resolver, so the tool surface and internal callers can never drift.
  """

  alias Sanctum.Context

  defdelegate resolve_component(ctx, reference), to: Compendium.Component
  defdelegate parse_reference(reference), to: Compendium.Component

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

  # The access-token endpoints answer a 401 with this bare atom rather than an
  # `Errors` struct: the IdP token is spent, and only a fresh OAuth round-trip
  # helps — a re-probe with the same token never will.
  def to_error_string(:invalid_access_token),
    do: "the provider access token expired or was revoked — sign in again"

  def to_error_string(err) when is_binary(err), do: err
  def to_error_string(err), do: inspect(err)

  # Find a bearer scoped to a specific namespace.
  def namespace_bearer(%Context{user_id: user_id}, slug)
      when is_binary(user_id) and user_id != "" and is_binary(slug) do
    registry = Compendium.RegistryHost.canonical_host()

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
