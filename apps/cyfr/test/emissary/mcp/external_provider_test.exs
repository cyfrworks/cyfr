# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ExternalProviderTest do
  use ExUnit.Case, async: false

  alias Emissary.MCP.ExternalProvider

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    ctx = Sanctum.TestContext.local()
    {:ok, ctx: ctx}
  end

  describe "try_handle/3" do
    test "returns :not_external for non-namespaced tools", %{ctx: ctx} do
      assert {:error, :not_external} =
               ExternalProvider.try_handle("regular_tool", ctx, %{})
    end

    test "returns :not_external when server doesn't exist", %{ctx: ctx} do
      assert {:error, :not_external} =
               ExternalProvider.try_handle("nonexistent:some_tool", ctx, %{})
    end

    test "returns error for disabled server", %{ctx: ctx} do
      Arca.McpServerStorage.put(ctx, %{
        name: "disabled-srv",
        url: "https://x.com/mcp",
        enabled: false
      })

      assert {:error, "Server 'disabled-srv' is disabled"} =
               ExternalProvider.try_handle("disabled-srv:tool", ctx, %{})
    end

    test "auto-starts server process on dispatch", %{ctx: ctx} do
      Arca.McpServerStorage.put(ctx, %{
        name: "autostart",
        url: "https://localhost:99999/mcp"
      })

      athanor_id = ctx.athanor_id

      # No process should be running yet
      assert [] =
               Registry.lookup(
                 Emissary.MCP.ExternalServerRegistry,
                 {"autostart", athanor_id}
               )

      # try_handle should auto-start the server (connection will fail, but process starts)
      result = ExternalProvider.try_handle("autostart:some_tool", ctx, %{})

      # The server process should now exist (started by try_handle)
      assert [{_pid, _}] =
               Registry.lookup(
                 Emissary.MCP.ExternalServerRegistry,
                 {"autostart", athanor_id}
               )

      # Result will be an error since the server can't connect, but it shouldn't be :not_external
      assert {:error, msg} = result
      refute msg == :not_external

      # Cleanup
      Emissary.MCP.ExternalServerSupervisor.stop("autostart", athanor_id)
    end

    test "dispatches to running server", %{ctx: ctx} do
      Arca.McpServerStorage.put(ctx, %{
        name: "dispatch-test",
        url: "https://localhost:99999/mcp"
      })

      athanor_id = ctx.athanor_id

      # Pre-start the server
      Emissary.MCP.ExternalServerSupervisor.ensure_started(
        name: "dispatch-test",
        url: "https://localhost:99999/mcp",
        athanor_id: athanor_id
      )

      # try_handle should dispatch (will fail at HTTP level, but not :not_external)
      assert {:error, msg} = ExternalProvider.try_handle("dispatch-test:tool", ctx, %{})
      refute msg == :not_external

      # Cleanup
      Emissary.MCP.ExternalServerSupervisor.stop("dispatch-test", athanor_id)
    end
  end

  describe "list_external_tools/1" do
    test "returns empty list when no servers configured", %{ctx: ctx} do
      assert [] = ExternalProvider.list_external_tools(ctx)
    end

    test "skips disabled servers", %{ctx: ctx} do
      Arca.McpServerStorage.put(ctx, %{
        name: "disabled",
        url: "https://x.com/mcp",
        enabled: false
      })

      assert [] = ExternalProvider.list_external_tools(ctx)
    end
  end
end
