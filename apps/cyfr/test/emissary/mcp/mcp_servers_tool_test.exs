# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.McpServersToolTest do
  use ExUnit.Case, async: false

  alias Emissary.MCP.McpServersTool

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    ctx = Sanctum.TestContext.local()
    {:ok, ctx: ctx}
  end

  describe "tools/0" do
    test "returns mcp_servers tool definition" do
      tools = McpServersTool.tools()
      assert length(tools) == 1

      tool = hd(tools)
      assert tool.name == "mcp_servers"
      assert tool.input_schema["required"] == ["action"]

      actions = tool.input_schema["properties"]["action"]["enum"]
      assert "create" in actions
      assert "delete" in actions
      assert "list" in actions
      assert "get" in actions
      assert "test" in actions
      assert "refresh" in actions
      assert "enable" in actions
      assert "disable" in actions
    end
  end

  describe "handle/3 - create" do
    test "requires name", %{ctx: ctx} do
      assert {:error, "Missing required parameter: name"} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "config" => %{"url" => "https://example.com/mcp"}
               })
    end

    test "requires config.url", %{ctx: ctx} do
      assert {:error, "Missing required parameter: config.url"} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "name" => "test",
                 "config" => %{}
               })
    end

    test "validates url format", %{ctx: ctx} do
      assert {:error, "Invalid URL:" <> _} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "name" => "test",
                 "config" => %{"url" => "not-a-url"}
               })
    end

    test "rejects name containing colon", %{ctx: ctx} do
      assert {:error, "Server name cannot contain ':'" <> _} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "name" => "foo:bar",
                 "config" => %{"url" => "https://example.com/mcp"}
               })
    end

    test "rejects SSRF URLs targeting metadata endpoints", %{ctx: ctx} do
      # In `:platform` mode, private IPs should be blocked
      result =
        McpServersTool.handle("mcp_servers", ctx, %{
          "action" => "create",
          "name" => "ssrf-test",
          "config" => %{"url" => "http://169.254.169.254/latest/meta-data/"}
        })

      assert {:error, "Invalid URL:" <> _} = result
    end

    test "enforces server count limit", %{ctx: ctx} do
      original = Application.get_env(:cyfr, :max_external_servers)
      Application.put_env(:cyfr, :max_external_servers, 2)

      # on_exit, not a trailing statement: a failing assertion below would skip
      # an inline restore and leave the limit at 2 for every later test in the
      # BEAM — which is how one failure here cascades into unrelated files.
      on_exit(fn ->
        if original,
          do: Application.put_env(:cyfr, :max_external_servers, original),
          else: Application.delete_env(:cyfr, :max_external_servers)
      end)

      # Add two servers (they'll fail to connect but get saved)
      McpServersTool.handle("mcp_servers", ctx, %{
        "action" => "create",
        "name" => "limit-s1",
        "config" => %{"url" => "https://localhost:99999/mcp"}
      })

      McpServersTool.handle("mcp_servers", ctx, %{
        "action" => "create",
        "name" => "limit-s2",
        "config" => %{"url" => "https://localhost:99999/mcp"}
      })

      # Third should be rejected
      assert {:error, "Maximum server limit (2) reached"} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "name" => "limit-s3",
                 "config" => %{"url" => "https://localhost:99999/mcp"}
               })
    end

    test "saves server config to storage", %{ctx: ctx} do
      # The actual HTTP connection will fail, but the config should be saved
      result =
        McpServersTool.handle("mcp_servers", ctx, %{
          "action" => "create",
          "name" => "test-save",
          "config" => %{"url" => "https://localhost:99999/mcp"}
        })

      assert {:ok, %{name: "test-save"}} = result

      # Verify it was persisted
      assert {:ok, server} = Arca.McpServerStorage.get(ctx, "test-save")
      assert server.url == "https://localhost:99999/mcp"
    end
  end

  describe "handle/3 - delete" do
    test "requires name", %{ctx: ctx} do
      assert {:error, "Missing required parameter: name"} =
               McpServersTool.handle("mcp_servers", ctx, %{"action" => "delete"})
    end

    test "deletes existing server", %{ctx: ctx} do
      Arca.McpServerStorage.put(ctx, %{name: "to-delete", url: "https://x.com/mcp"})

      assert {:ok, %{deleted: "to-delete"}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "delete",
                 "name" => "to-delete"
               })

      assert {:error, :not_found} = Arca.McpServerStorage.get(ctx, "to-delete")
    end
  end

  describe "handle/3 - list" do
    test "returns empty list when no servers configured", %{ctx: ctx} do
      assert {:ok, %{servers: [], count: 0}} =
               McpServersTool.handle("mcp_servers", ctx, %{"action" => "list"})
    end

    test "returns configured servers", %{ctx: ctx} do
      Arca.McpServerStorage.put(ctx, %{name: "s1", url: "https://a.com/mcp"})
      Arca.McpServerStorage.put(ctx, %{name: "s2", url: "https://b.com/mcp"})

      assert {:ok, %{servers: servers, count: 2}} =
               McpServersTool.handle("mcp_servers", ctx, %{"action" => "list"})

      names = Enum.map(servers, & &1.name)
      assert "s1" in names
      assert "s2" in names
    end

    test "listing starts no server processes", %{ctx: ctx} do
      # A read must read: listing used to ensure_started every enabled
      # server, so any authenticated caller could open outbound connections
      # as a side effect. Invocation starts servers on demand instead.
      Arca.McpServerStorage.put(ctx, %{name: "lazy-1", url: "https://a.com/mcp", enabled: true})

      assert {:ok, %{servers: [server]}} =
               McpServersTool.handle("mcp_servers", ctx, %{"action" => "list"})

      assert server.status == "disconnected"

      assert Registry.lookup(
               Emissary.MCP.ExternalServerRegistry,
               {"lazy-1", ctx.athanor_id}
             ) == []
    end

    test "list and get are not in-chain reachable" do
      [tool] = McpServersTool.tools()

      for action <- ["list", "get"] do
        planes = get_in(tool, [:annotations, :actions, action, :planes])
        assert planes == [:external], "mcp_servers.#{action} must not be a chain capability"
      end
    end
  end

  describe "handle/3 - get" do
    test "requires name", %{ctx: ctx} do
      assert {:error, "Missing required parameter: name"} =
               McpServersTool.handle("mcp_servers", ctx, %{"action" => "get"})
    end

    test "requires non-empty name", %{ctx: ctx} do
      assert {:error, "Missing required parameter: name"} =
               McpServersTool.handle("mcp_servers", ctx, %{"action" => "get", "name" => ""})
    end

    test "returns error for non-existent server", %{ctx: ctx} do
      assert {:error, "Server 'nonexistent' not found"} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "get",
                 "name" => "nonexistent"
               })
    end

    test "returns server details for existing server", %{ctx: ctx} do
      Arca.McpServerStorage.put(ctx, %{name: "get-test", url: "https://x.com/mcp"})

      assert {:ok, %{name: "get-test", url: "https://x.com/mcp"}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "get",
                 "name" => "get-test"
               })
    end
  end

  describe "handle/3 - test" do
    test "requires name", %{ctx: ctx} do
      assert {:error, "Missing required parameter: name"} =
               McpServersTool.handle("mcp_servers", ctx, %{"action" => "test"})
    end

    test "requires non-empty name", %{ctx: ctx} do
      assert {:error, "Missing required parameter: name"} =
               McpServersTool.handle("mcp_servers", ctx, %{"action" => "test", "name" => ""})
    end

    test "returns error for non-existent server", %{ctx: ctx} do
      assert {:error, "Server 'nonexistent' not found"} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "test",
                 "name" => "nonexistent"
               })
    end

    test "returns status for existing server", %{ctx: ctx} do
      Arca.McpServerStorage.put(ctx, %{name: "test-srv", url: "https://localhost:99999/mcp"})

      # Will fail to connect but should return a status result, not a not_found error
      assert {:ok, %{name: "test-srv"}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "test",
                 "name" => "test-srv"
               })
    end
  end

  describe "handle/3 - refresh" do
    test "returns error for non-existent named server", %{ctx: ctx} do
      assert {:error, "Server 'nonexistent' not found"} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "refresh",
                 "name" => "nonexistent"
               })
    end

    test "refreshes all servers when no name given", %{ctx: ctx} do
      # With no servers, should return empty results
      assert {:ok, %{refreshed: [], failed: []}} =
               McpServersTool.handle("mcp_servers", ctx, %{"action" => "refresh"})
    end

    test "refreshes all servers with empty name", %{ctx: ctx} do
      assert {:ok, %{refreshed: _, failed: _}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "refresh",
                 "name" => ""
               })
    end
  end

  describe "handle/3 - enable/disable" do
    test "disables a server", %{ctx: ctx} do
      Arca.McpServerStorage.put(ctx, %{name: "toggle", url: "https://x.com/mcp"})

      assert {:ok, %{enabled: false}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "disable",
                 "name" => "toggle"
               })

      assert {:ok, server} = Arca.McpServerStorage.get(ctx, "toggle")
      assert server.enabled == false
    end

    test "enables a disabled server", %{ctx: ctx} do
      Arca.McpServerStorage.put(ctx, %{name: "toggle2", url: "https://x.com/mcp", enabled: false})

      assert {:ok, %{enabled: true}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "enable",
                 "name" => "toggle2"
               })
    end
  end

  describe "handle/3 - unknown" do
    test "returns error for unknown action", %{ctx: ctx} do
      assert {:error, "Unknown action: " <> _} =
               McpServersTool.handle("mcp_servers", ctx, %{"action" => "bogus"})
    end

    test "returns error for missing action", %{ctx: ctx} do
      assert {:error, "Missing required parameter: action"} =
               McpServersTool.handle("mcp_servers", ctx, %{})
    end

    test "returns error for unknown tool", %{ctx: ctx} do
      assert {:error, "Unknown tool: other"} =
               McpServersTool.handle("other", ctx, %{"action" => "list"})
    end
  end
end
