# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ResourceReadAuditTest do
  # Not async: reads the live resource registry the application owns.
  use ExUnit.Case, async: false

  alias Emissary.MCP.ResourceRegistry
  alias Sanctum.Context

  @moduledoc """
  `resources/read` is the one provider entry point outside the tool
  dispatcher's annotation gate — the Router leaves it unauthenticated by
  design and each provider's `read/2` enforces its own authorization. This
  audit holds every registered resource to that contract: an anonymous read
  either refuses or returns nothing beyond the caller's own (empty) context.
  A new resource that serves tenant data without a gate fails here.
  """

  test "every registered resource refuses anonymous reads or echoes only the caller" do
    anonymous =
      Context.build(
        user_id: nil,
        athanor_id: nil,
        permissions: [],
        auth_method: nil,
        authenticated: false
      )

    self_describing = ["sanctum://identity", "sanctum://permissions"]

    for %{"uri" => uri} <- ResourceRegistry.list_resources() do
      case ResourceRegistry.read(anonymous, uri) do
        {:error, _reason} ->
          :ok

        {:ok, _content} ->
          assert uri in self_describing,
                 "anonymous read of #{uri} succeeded — a resource read handler " <>
                   "must enforce its own authorization (the Router deliberately does not)"
      end
    end
  end

  # Templates never appear in `list_resources/0`, so the audit above cannot
  # see them — which is exactly how `arca://files/{path}` shipped without a
  # permission gate. Expanding each `{placeholder}` to a probe value and
  # asserting the refusal is authorization-shaped (never a not-found from a
  # data access that already happened) holds template handlers to the same
  # contract.
  test "every registered resource template refuses unauthorized reads before touching data" do
    anonymous =
      Context.build(
        user_id: nil,
        athanor_id: nil,
        permissions: [],
        auth_method: nil,
        authenticated: false
      )

    permissionless =
      Context.build(
        user_id: "user_audit",
        athanor_id: "ath_audit",
        permissions: [],
        auth_method: :api_key,
        authenticated: true
      )

    templates = ResourceRegistry.list_resource_templates()
    assert templates != [], "no resource templates registered — audit is vacuous"

    for %{"uriTemplate" => template} <- templates,
        uri = String.replace(template, ~r/\{[^}]+\}/, "probe"),
        {label, ctx} <- [anonymous: anonymous, permissionless: permissionless] do
      case ResourceRegistry.read(ctx, uri) do
        {:error, reason} ->
          assert Sanctum.Unauthorized.reason?(reason) or
                   (is_binary(reason) and reason =~ ~r/Authentication required|Unauthorized/),
                 "#{label} read of #{uri} was refused with #{inspect(reason)} — " <>
                   "the gate must fire before any data access, not fall through " <>
                   "to a not-found"

        {:ok, _content} ->
          flunk(
            "#{label} read of #{uri} succeeded — a resource template handler " <>
              "must enforce its own authorization (the Router deliberately does not)"
          )
      end
    end
  end
end
