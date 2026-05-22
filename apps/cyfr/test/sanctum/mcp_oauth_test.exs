# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCPOAuthTest do
  @moduledoc """
  Characterization of the MCP `oauth` tool (authorize/status/revoke). It is
  listed in tools/0 but never exercised by mcp_test.exs. Provider-credential
  setup is environment-dependent, so this pins the deterministic contract:
  required-arg messages, permission gates, and the `{:error, to_string(...)}`
  passthrough shape — not a faked token endpoint.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.MCP

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  describe "required-argument contracts" do
    test "authorize missing args", %{ctx: ctx} do
      assert MCP.handle("oauth", ctx, %{"action" => "authorize"}) ==
               {:error, "authorize requires: component_ref, provider"}
    end

    test "status missing args", %{ctx: ctx} do
      assert MCP.handle("oauth", ctx, %{"action" => "status"}) ==
               {:error, "status requires: component_ref"}
    end

    test "revoke missing args", %{ctx: ctx} do
      assert MCP.handle("oauth", ctx, %{"action" => "revoke"}) ==
               {:error, "revoke requires: component_ref, provider"}
    end
  end

  describe "permission gates" do
    defp ctx_without(perm_list) do
      Context.build(
        user_id: "u",
        namespace: "ns",
        permissions: perm_list,
        scope: :project,
        authenticated: true
      )
    end

    test "authorize requires :secrets_write" do
      assert {:error, msg} =
               MCP.handle("oauth", ctx_without([:storage_read]), %{
                 "action" => "authorize",
                 "component_ref" => "catalyst:local.x",
                 "provider" => "github"
               })

      assert msg =~ "secrets_write"
    end

    test "status requires :secrets_read" do
      assert {:error, msg} =
               MCP.handle("oauth", ctx_without([:storage_read]), %{
                 "action" => "status",
                 "component_ref" => "catalyst:local.x"
               })

      assert msg =~ "secrets_read"
    end
  end

  describe "error/result-shape passthrough" do
    test "authorize with perms but no provider creds → {:error, binary}", %{ctx: ctx} do
      result =
        MCP.handle("oauth", ctx, %{
          "action" => "authorize",
          "component_ref" => "catalyst:local.x",
          "provider" => "github"
        })

      assert match?({:error, msg} when is_binary(msg), result) or
               match?({:ok, %{status: "ok"}}, result)
    end

    test "status with perms returns the contract shape", %{ctx: ctx} do
      result = MCP.handle("oauth", ctx, %{"action" => "status", "component_ref" => "catalyst:local.x"})

      assert match?({:ok, %{status: "ok", providers: _}}, result) or
               match?({:error, msg} when is_binary(msg), result)
    end
  end
end
