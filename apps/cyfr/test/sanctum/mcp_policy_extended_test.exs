# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCPPolicyExtendedTest do
  @moduledoc """
  Characterization of the MCP `policy` actions not exercised by mcp_test.exs:
  get_ceiling, *_type_default, and the `require_policy_ownership` gate (via
  `migrate`). These move during the MCP split — pin them first.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.MCP

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  describe "get_ceiling" do
    test "returns the effective ceiling map", %{ctx: ctx} do
      assert {:ok, %{ceiling: ceiling}} =
               MCP.handle("policy", ctx, %{"action" => "get_ceiling"})

      assert is_map(ceiling)
    end

    test "non-%Context{} → Authentication required" do
      assert MCP.handle("policy", nil, %{"action" => "get_ceiling"}) ==
               {:error, "Authentication required"}
    end
  end

  describe "*_type_default actions" do
    test "get_type_default with no stored row → hardcoded source", %{ctx: ctx} do
      assert {:ok, %{component_type: "catalyst", source: "hardcoded", policy: pmap}} =
               MCP.handle("policy", ctx, %{
                 "action" => "get_type_default",
                 "component_type" => "catalyst"
               })

      assert is_map(pmap)
    end

    test "get_type_default missing component_type → exact error", %{ctx: ctx} do
      assert MCP.handle("policy", ctx, %{"action" => "get_type_default"}) ==
               {:error, "Missing required argument: component_type"}
    end

    test "set → get round-trips to stored; delete returns to hardcoded", %{ctx: ctx} do
      {:ok, %{policy: pmap}} =
        MCP.handle("policy", ctx, %{"action" => "get_type_default", "component_type" => "reagent"})

      assert MCP.handle("policy", ctx, %{
               "action" => "set_type_default",
               "component_type" => "reagent",
               "policy" => pmap
             }) == {:ok, %{stored: true, component_type: "reagent"}}

      assert {:ok, %{source: "stored"}} =
               MCP.handle("policy", ctx, %{
                 "action" => "get_type_default",
                 "component_type" => "reagent"
               })

      assert MCP.handle("policy", ctx, %{
               "action" => "delete_type_default",
               "component_type" => "reagent"
             }) == {:ok, %{deleted: true, component_type: "reagent"}}

      assert {:ok, %{source: "hardcoded"}} =
               MCP.handle("policy", ctx, %{
                 "action" => "get_type_default",
                 "component_type" => "reagent"
               })
    end

    test "set_type_default missing args → exact error", %{ctx: ctx} do
      assert MCP.handle("policy", ctx, %{"action" => "set_type_default"}) ==
               {:error, "Missing required arguments: component_type, policy"}
    end

    test "delete_type_default missing component_type → exact error", %{ctx: ctx} do
      assert MCP.handle("policy", ctx, %{"action" => "delete_type_default"}) ==
               {:error, "Missing required argument: component_type"}
    end

    test "list_type_defaults returns a type_defaults list", %{ctx: ctx} do
      assert {:ok, %{type_defaults: defaults}} =
               MCP.handle("policy", ctx, %{"action" => "list_type_defaults"})

      assert is_list(defaults)
    end
  end

  describe "require_policy_ownership gate (via migrate)" do
    defp non_admin_ctx do
      Context.build(
        user_id: "owner",
        namespace: "ns",
        permissions: [:policy_manage],
        scope: :project,
        authenticated: true
      )
    end

    test "non-admin + non-local ref → unauthorized" do
      assert MCP.handle("policy", non_admin_ctx(), %{
               "action" => "migrate",
               "component_ref" => "catalyst:acme.foo:1.0.0"
             }) ==
               {:error,
                "Unauthorized: modifying policies for non-local components requires admin permission"}
    end

    test "non-admin + local ref passes ownership (then hits not-found)" do
      assert {:error, msg} =
               MCP.handle("policy", non_admin_ctx(), %{
                 "action" => "migrate",
                 "component_ref" => "catalyst:local.foo:1.0.0"
               })

      assert msg =~ "No version-specific policy found for"
    end

    test "admin/wildcard bypasses the ownership gate for a non-local ref", %{ctx: ctx} do
      # ctx is TestContext.local/0 → has :* → require_policy_ownership returns
      # :ok regardless of namespace; falls through to the not-found path.
      assert {:error, msg} =
               MCP.handle("policy", ctx, %{
                 "action" => "migrate",
                 "component_ref" => "catalyst:acme.bar:2.0.0"
               })

      assert msg =~ "No version-specific policy found for"
    end
  end
end
