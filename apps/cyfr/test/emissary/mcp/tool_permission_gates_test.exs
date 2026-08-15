# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ToolPermissionGatesTest do
  use ExUnit.Case, async: false

  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp execute_only_ctx do
    Context.build(
      user_id: "exec-only",
      org_id: "local",
      project_id: "default",
      scope: :project,
      permissions: [:execute, :storage_read, :storage_write],
      authenticated: true
    )
  end

  describe "mcp_servers management requires :admin" do
    test "mutating actions are denied for an execute-only context" do
      ctx = execute_only_ctx()

      for action <- ~w(create delete enable disable test refresh) do
        assert {:error, message} =
                 Emissary.MCP.ExternalProvider.handle("mcp_servers", ctx, %{
                   "action" => action,
                   "name" => "some-server"
                 })

        assert message =~ "admin", "expected admin denial for #{action}, got: #{message}"
      end
    end

    test "reads stay open to authenticated callers" do
      ctx = execute_only_ctx()

      assert {:ok, %{servers: _}} =
               Emissary.MCP.ExternalProvider.handle("mcp_servers", ctx, %{"action" => "list"})
    end
  end

  describe "registry identity mutations require :component_manage" do
    test "namespace/token/member mutations are denied for an execute-only context" do
      ctx = execute_only_ctx()

      for action <-
            ~w(claim_publisher verify_publisher tokens_issue tokens_revoke members_add members_update members_remove) do
        assert {:error, message} =
                 Compendium.MCP.RegistryTool.handle(ctx, %{
                   "action" => action,
                   "slug" => "someslug"
                 })

        assert message =~ "component_manage",
               "expected component_manage denial for #{action}, got: #{message}"
      end
    end

    test "whoami stays open" do
      ctx = execute_only_ctx()
      assert {:ok, _identity} = Compendium.MCP.RegistryTool.handle(ctx, %{"action" => "whoami"})
    end
  end

  describe "mcp_servers.create rejects plaintext credential headers" do
    defp create_args(headers) do
      %{
        "action" => "create",
        "name" => "hdr-test-#{System.unique_integer([:positive])}",
        "config" => %{"url" => "https://example.com/mcp", "headers" => headers}
      }
    end

    test "a literal authorization header is rejected with an actionable error" do
      ctx = Sanctum.TestContext.local()

      assert {:error, message} =
               Emissary.MCP.ExternalProvider.handle(
                 "mcp_servers",
                 ctx,
                 create_args(%{"Authorization" => "Bearer sk-live-plaintext"})
               )

      assert message =~ "vault:CONNECTION"
      assert message =~ "Authorization"
    end

    test "credential-shaped custom headers are rejected too" do
      ctx = Sanctum.TestContext.local()

      for header <- ["X-Api-Key", "X-Access-Token", "My-Secret"] do
        assert {:error, _} =
                 Emissary.MCP.ExternalProvider.handle(
                   "mcp_servers",
                   ctx,
                   create_args(%{header => "literal-value"})
                 )
      end
    end

    test "vault references and innocuous literals are accepted; secret: refs are not" do
      ctx = Sanctum.TestContext.local()

      assert {:ok, _} =
               Emissary.MCP.ExternalProvider.handle(
                 "mcp_servers",
                 ctx,
                 create_args(%{
                   "Authorization" => "vault:my-token",
                   "Content-Type" => "application/json",
                   "X-Client-Version" => "1.2.3"
                 })
               )

      # The secrets plane is retired: a secret: reference is rejected at
      # create with a message naming the vault: replacement.
      assert {:error, msg} =
               Emissary.MCP.ExternalProvider.handle(
                 "mcp_servers",
                 ctx,
                 create_args(%{"Authorization" => "secret:MY_TOKEN"})
               )

      assert msg =~ "vault:"

      # Even in a header whose NAME is not credential-shaped — otherwise the
      # row persists and only fails at server boot.
      assert {:error, _} =
               Emissary.MCP.ExternalProvider.handle(
                 "mcp_servers",
                 ctx,
                 create_args(%{"X-Thing" => "secret:MY_TOKEN"})
               )
    end
  end

  describe "system.notify requires :admin" do
    test "denied for an execute-only context" do
      ctx = execute_only_ctx()

      assert {:error, message} =
               Emissary.MCP.Tools.SystemProvider.handle("system", ctx, %{
                 "action" => "notify",
                 "event" => "test.event"
               })

      assert message =~ "admin"
    end

    test "status stays open" do
      ctx = execute_only_ctx()

      assert {:ok, %{status: _}} =
               Emissary.MCP.Tools.SystemProvider.handle("system", ctx, %{"action" => "status"})
    end
  end
end
