# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Providers.Shared do
  @moduledoc """
  Helpers shared across the Compendium MCP tool modules
  (`Compendium.Provider` facade, `Compendium.Providers.Component`,
  `Compendium.Providers.Aqua`, `Compendium.Providers.Registry`).

  Component resolution delegates to `Compendium.Component` — the one
  resolver, so the tool surface and internal callers can never drift.
  """

  alias Sanctum.Context

  defdelegate resolve_component(ctx, reference), to: Compendium.Component
  defdelegate parse_reference(reference), to: Compendium.Component

  @doc """
  A registry's own refusal as the gate's normalized form, at the
  provider's edge: a `%Compendium.OCI.Errors{}` becomes a
  `%Prima.Refusal{}` classed by the registry's HTTP answer — 401
  `unauthenticated`, 403 `forbidden`, 404 `not_found`, 429
  `rate_limited`, anything else `unavailable` — with reason
  `{:registry, oci_reason}`, so the struct never reaches the gate. Its
  sentence is `Compendium.OCI.Errors.to_string/1` with the actionable
  hint; the verbose `detail` stays in the client's log. The access-token
  endpoints' bare `:invalid_access_token` is the provider's spent IdP
  token. Any other reason is returned as it is, for the gate to classify.
  """
  @spec refusal(term()) :: term()
  def refusal(%Compendium.OCI.Errors{} = err) do
    msg = Compendium.OCI.Errors.to_string(err)
    hint = Compendium.OCI.Errors.actionable_hint(err)

    %Prima.Refusal{
      class: registry_class(err.status),
      reason: {:registry, err.reason},
      message: if(hint != "", do: "#{msg}. #{hint}", else: msg)
    }
  end

  # The access-token endpoints answer a 401 with this bare atom rather than an
  # `Errors` struct: the IdP token is spent, and only a fresh OAuth round-trip
  # helps — a re-probe with the same token never will.
  def refusal(:invalid_access_token) do
    %Prima.Refusal{
      class: :unauthenticated,
      reason: :invalid_access_token,
      message: "the provider access token expired or was revoked — sign in again"
    }
  end

  def refusal(reason), do: reason

  defp registry_class(401), do: :unauthenticated
  defp registry_class(403), do: :forbidden
  defp registry_class(404), do: :not_found
  defp registry_class(429), do: :rate_limited
  defp registry_class(_status), do: :unavailable

  # Find a bearer scoped to a specific namespace.
  def namespace_bearer(%Context{user_id: user_id} = ctx, slug)
      when is_binary(user_id) and user_id != "" and is_binary(slug) do
    registry = Compendium.RegistryHost.canonical_host()

    case Compendium.Registry.CredentialStore.get(ctx, registry, slug) do
      {:ok, %{type: :push_token, token: token}} when is_binary(token) ->
        {:ok, token}

      # A store that cannot answer, and a stored token that cannot be
      # opened, are neither "no token": each refuses as unavailable, never
      # as a prompt to sign in again over a credential that is there.
      {:error, :unavailable} ->
        {:error, {:unavailable, "Registry credentials"}}

      {:error, :corrupt} ->
        {:error, {:unavailable, "The push token stored for namespace '#{slug}'"}}

      _ ->
        {:error, "no push token for namespace '#{slug}' — run `cyfr login`"}
    end
  end

  def namespace_bearer(_, _), do: {:error, "authentication required"}

  # deprecate/yank require a fully-qualified ref (all four fields).
  # Prima.ComponentRef.parse/1 can succeed with version=nil for
  # `c:alice.foo` (latest); these actions must target a specific version.
  def ensure_fully_qualified(%Prima.ComponentRef{version: nil}),
    do: {:error, "deprecate/yank require a pinned version, e.g. c:alice.foo:1.0.0"}

  def ensure_fully_qualified(%Prima.ComponentRef{version: ""}),
    do: {:error, "deprecate/yank require a pinned version, e.g. c:alice.foo:1.0.0"}

  def ensure_fully_qualified(%Prima.ComponentRef{}), do: :ok
end
