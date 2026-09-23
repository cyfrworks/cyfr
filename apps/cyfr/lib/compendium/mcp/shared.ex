# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.MCP.Shared do
  @moduledoc """
  Helpers shared across the Compendium MCP tool modules
  (`Compendium.MCP` facade, `ComponentTool`, `AquaTool`, `RegistryTool`).

  Component resolution delegates to `Compendium.Component` — the one
  resolver, so the tool surface and internal callers can never drift.
  """

  require Logger

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

  # Atoms are refusal vocabulary — safe words by construction. Anything
  # else is an internal term: logged here, never rendered.
  def to_error_string(err) when is_atom(err) and not is_nil(err) and not is_boolean(err),
    do: err |> Atom.to_string() |> String.replace("_", " ")

  def to_error_string(err) do
    if Cyfr.Refusal.reason?(err) do
      Cyfr.Refusal.message(err)
    else
      Logger.warning("[Compendium.MCP.Shared] unrenderable error: #{inspect(err)}")
      "The registry request failed — try again."
    end
  end

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
  # Cyfr.ComponentRef.parse/1 can succeed with version=nil for
  # `c:alice.foo` (latest); these actions must target a specific version.
  def ensure_fully_qualified(%Cyfr.ComponentRef{version: nil}),
    do: {:error, "deprecate/yank require a pinned version, e.g. c:alice.foo:1.0.0"}

  def ensure_fully_qualified(%Cyfr.ComponentRef{version: ""}),
    do: {:error, "deprecate/yank require a pinned version, e.g. c:alice.foo:1.0.0"}

  def ensure_fully_qualified(%Cyfr.ComponentRef{}), do: :ok
end
