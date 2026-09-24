# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ResourceReadAuditTest do
  # Not async: reads the live resource catalogue the application owns and
  # runs reads through the shared-mode sandbox.
  use ExUnit.Case, async: false

  alias Emissary.MCP.{Message, Router}
  alias Grimoire.Resources
  alias Sanctum.Context

  @moduledoc """
  `resources/read` is an ordinary operation call: the Router resolves the
  URI's scheme to the operation that declares it and the catalog's gate
  admits or refuses it. This audit holds every advertised resource and
  template to that: an anonymous read, or one by a key holding no
  permission, is refused with an authorization error before any data is
  read — except the two `sanctum://` self-descriptions, which answer any
  caller its own (empty) identity. A new resource that serves data without
  a gate fails here.
  """

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  @self_describing ["sanctum://identity", "sanctum://permissions"]

  defp anonymous do
    Context.build(
      user_id: nil,
      athanor_id: nil,
      permissions: [],
      auth_method: nil,
      authenticated: false
    )
  end

  defp permissionless do
    Context.build(
      user_id: "user_audit",
      athanor_id: "ath_audit",
      permissions: [],
      auth_method: :api_key,
      authenticated: true
    )
  end

  defp read(ctx, uri) do
    Router.dispatch(ctx, %Message{
      type: :request,
      id: 1,
      method: "resources/read",
      params: %{"uri" => uri}
    })
  end

  test "every advertised resource refuses anonymous reads or echoes only the caller" do
    resources = Resources.list_resources()
    assert resources != [], "no resources registered — audit is vacuous"

    for %{"uri" => uri} <- resources do
      case read(anonymous(), uri) do
        {:error, code, _message} ->
          assert code == :auth_required,
                 "anonymous read of #{uri} was refused as #{inspect(code)}, not by the gate"

        {:ok, %{"contents" => [%{"text" => text}]}} ->
          assert uri in @self_describing,
                 "anonymous read of #{uri} succeeded — its declaring operation must " <>
                   "require authentication"

          # The caller's own empty identity: no stored tenant data.
          for {_key, value} <- Jason.decode!(text), do: assert(value in [nil, [], "athanor"])
      end
    end
  end

  # Templates never appear in `list_resources/0`, so the audit above cannot
  # see them. Expanding each `{placeholder}` to a probe value and asserting
  # the refusal is authorization-shaped (never a not-found from a data
  # access that already happened) holds template reads to the same gate.
  test "every advertised resource template refuses unauthorized reads before touching data" do
    templates = Resources.list_resource_templates()
    assert templates != [], "no resource templates registered — audit is vacuous"

    for %{"uriTemplate" => template} <- templates,
        uri = String.replace(template, ~r/\{[^}]+\}/, "probe"),
        {label, ctx, code} <- [
          anonymous: {anonymous(), :auth_required},
          permissionless: {permissionless(), :insufficient_permissions}
        ] do
      case read(ctx, uri) do
        {:error, ^code, message} ->
          assert message =~ "Unauthorized"

        other ->
          flunk(
            "#{label} read of #{uri} answered #{inspect(other)} — the gate must refuse " <>
              "before any data access"
          )
      end
    end
  end
end
