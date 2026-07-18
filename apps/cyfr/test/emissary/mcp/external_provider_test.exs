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

  describe "tools/0" do
    test "returns mcp_servers tool definition" do
      tools = ExternalProvider.tools()
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
               ExternalProvider.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "config" => %{"url" => "https://example.com/mcp"}
               })
    end

    test "requires config.url", %{ctx: ctx} do
      assert {:error, "Missing required parameter: config.url"} =
               ExternalProvider.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "name" => "test",
                 "config" => %{}
               })
    end

    test "validates url format", %{ctx: ctx} do
      assert {:error, "Invalid URL:" <> _} =
               ExternalProvider.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "name" => "test",
                 "config" => %{"url" => "not-a-url"}
               })
    end

    test "rejects name containing colon", %{ctx: ctx} do
      assert {:error, "Server name cannot contain ':'" <> _} =
               ExternalProvider.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "name" => "foo:bar",
                 "config" => %{"url" => "https://example.com/mcp"}
               })
    end

    test "rejects SSRF URLs targeting metadata endpoints", %{ctx: ctx} do
      # In `:platform` mode, private IPs should be blocked
      result =
        ExternalProvider.handle("mcp_servers", ctx, %{
          "action" => "create",
          "name" => "ssrf-test",
          "config" => %{"url" => "http://169.254.169.254/latest/meta-data/"}
        })

      assert {:error, "Invalid URL:" <> _} = result
    end

    test "enforces server count limit", %{ctx: ctx} do
      original = Application.get_env(:cyfr, :max_external_servers)
      Application.put_env(:cyfr, :max_external_servers, 2)

      # Add two servers (they'll fail to connect but get saved)
      ExternalProvider.handle("mcp_servers", ctx, %{
        "action" => "create",
        "name" => "limit-s1",
        "config" => %{"url" => "https://localhost:99999/mcp"}
      })

      ExternalProvider.handle("mcp_servers", ctx, %{
        "action" => "create",
        "name" => "limit-s2",
        "config" => %{"url" => "https://localhost:99999/mcp"}
      })

      # Third should be rejected
      assert {:error, "Maximum server limit (2) reached"} =
               ExternalProvider.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "name" => "limit-s3",
                 "config" => %{"url" => "https://localhost:99999/mcp"}
               })

      if original,
        do: Application.put_env(:cyfr, :max_external_servers, original),
        else: Application.delete_env(:cyfr, :max_external_servers)
    end

    test "saves server config to storage", %{ctx: ctx} do
      # The actual HTTP connection will fail, but the config should be saved
      result =
        ExternalProvider.handle("mcp_servers", ctx, %{
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
               ExternalProvider.handle("mcp_servers", ctx, %{"action" => "delete"})
    end

    test "deletes existing server", %{ctx: ctx} do
      Arca.McpServerStorage.put(ctx, %{name: "to-delete", url: "https://x.com/mcp"})

      assert {:ok, %{deleted: "to-delete"}} =
               ExternalProvider.handle("mcp_servers", ctx, %{
                 "action" => "delete",
                 "name" => "to-delete"
               })

      assert {:error, :not_found} = Arca.McpServerStorage.get(ctx, "to-delete")
    end
  end

  describe "handle/3 - list" do
    test "returns empty list when no servers configured", %{ctx: ctx} do
      assert {:ok, %{servers: [], count: 0}} =
               ExternalProvider.handle("mcp_servers", ctx, %{"action" => "list"})
    end

    test "returns configured servers", %{ctx: ctx} do
      Arca.McpServerStorage.put(ctx, %{name: "s1", url: "https://a.com/mcp"})
      Arca.McpServerStorage.put(ctx, %{name: "s2", url: "https://b.com/mcp"})

      assert {:ok, %{servers: servers, count: 2}} =
               ExternalProvider.handle("mcp_servers", ctx, %{"action" => "list"})

      names = Enum.map(servers, & &1.name)
      assert "s1" in names
      assert "s2" in names
    end
  end

  describe "handle/3 - get" do
    test "requires name", %{ctx: ctx} do
      assert {:error, "Missing required parameter: name"} =
               ExternalProvider.handle("mcp_servers", ctx, %{"action" => "get"})
    end

    test "requires non-empty name", %{ctx: ctx} do
      assert {:error, "Missing required parameter: name"} =
               ExternalProvider.handle("mcp_servers", ctx, %{"action" => "get", "name" => ""})
    end

    test "returns error for non-existent server", %{ctx: ctx} do
      assert {:error, "Server 'nonexistent' not found"} =
               ExternalProvider.handle("mcp_servers", ctx, %{
                 "action" => "get",
                 "name" => "nonexistent"
               })
    end

    test "returns server details for existing server", %{ctx: ctx} do
      Arca.McpServerStorage.put(ctx, %{name: "get-test", url: "https://x.com/mcp"})

      assert {:ok, %{name: "get-test", url: "https://x.com/mcp"}} =
               ExternalProvider.handle("mcp_servers", ctx, %{
                 "action" => "get",
                 "name" => "get-test"
               })
    end
  end

  describe "handle/3 - test" do
    test "requires name", %{ctx: ctx} do
      assert {:error, "Missing required parameter: name"} =
               ExternalProvider.handle("mcp_servers", ctx, %{"action" => "test"})
    end

    test "requires non-empty name", %{ctx: ctx} do
      assert {:error, "Missing required parameter: name"} =
               ExternalProvider.handle("mcp_servers", ctx, %{"action" => "test", "name" => ""})
    end

    test "returns error for non-existent server", %{ctx: ctx} do
      assert {:error, "Server 'nonexistent' not found"} =
               ExternalProvider.handle("mcp_servers", ctx, %{
                 "action" => "test",
                 "name" => "nonexistent"
               })
    end

    test "returns status for existing server", %{ctx: ctx} do
      Arca.McpServerStorage.put(ctx, %{name: "test-srv", url: "https://localhost:99999/mcp"})

      # Will fail to connect but should return a status result, not a not_found error
      assert {:ok, %{name: "test-srv"}} =
               ExternalProvider.handle("mcp_servers", ctx, %{
                 "action" => "test",
                 "name" => "test-srv"
               })
    end
  end

  describe "handle/3 - refresh" do
    test "returns error for non-existent named server", %{ctx: ctx} do
      assert {:error, "Server 'nonexistent' not found"} =
               ExternalProvider.handle("mcp_servers", ctx, %{
                 "action" => "refresh",
                 "name" => "nonexistent"
               })
    end

    test "refreshes all servers when no name given", %{ctx: ctx} do
      # With no servers, should return empty results
      assert {:ok, %{refreshed: [], failed: []}} =
               ExternalProvider.handle("mcp_servers", ctx, %{"action" => "refresh"})
    end

    test "refreshes all servers with empty name", %{ctx: ctx} do
      assert {:ok, %{refreshed: _, failed: _}} =
               ExternalProvider.handle("mcp_servers", ctx, %{
                 "action" => "refresh",
                 "name" => ""
               })
    end
  end

  describe "handle/3 - enable/disable" do
    test "disables a server", %{ctx: ctx} do
      Arca.McpServerStorage.put(ctx, %{name: "toggle", url: "https://x.com/mcp"})

      assert {:ok, %{enabled: false}} =
               ExternalProvider.handle("mcp_servers", ctx, %{
                 "action" => "disable",
                 "name" => "toggle"
               })

      assert {:ok, server} = Arca.McpServerStorage.get(ctx, "toggle")
      assert server.enabled == false
    end

    test "enables a disabled server", %{ctx: ctx} do
      Arca.McpServerStorage.put(ctx, %{name: "toggle2", url: "https://x.com/mcp", enabled: false})

      assert {:ok, %{enabled: true}} =
               ExternalProvider.handle("mcp_servers", ctx, %{
                 "action" => "enable",
                 "name" => "toggle2"
               })
    end
  end

  describe "handle/3 - unknown" do
    test "returns error for unknown action", %{ctx: ctx} do
      assert {:error, "Unknown action: " <> _} =
               ExternalProvider.handle("mcp_servers", ctx, %{"action" => "bogus"})
    end

    test "returns error for missing action", %{ctx: ctx} do
      assert {:error, "Missing required parameter: action"} =
               ExternalProvider.handle("mcp_servers", ctx, %{})
    end

    test "returns error for unknown tool", %{ctx: ctx} do
      assert {:error, "Unknown tool: other"} =
               ExternalProvider.handle("other", ctx, %{"action" => "list"})
    end
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

      org_id = ctx.org_id || ""
      project_id = ctx.project_id || "default"

      # No process should be running yet
      assert [] =
               Registry.lookup(
                 Emissary.MCP.ExternalServerRegistry,
                 {"autostart", org_id, project_id}
               )

      # try_handle should auto-start the server (connection will fail, but process starts)
      result = ExternalProvider.try_handle("autostart:some_tool", ctx, %{})

      # The server process should now exist (started by try_handle)
      assert [{_pid, _}] =
               Registry.lookup(
                 Emissary.MCP.ExternalServerRegistry,
                 {"autostart", org_id, project_id}
               )

      # Result will be an error since the server can't connect, but it shouldn't be :not_external
      assert {:error, msg} = result
      refute msg == :not_external

      # Cleanup
      Emissary.MCP.ExternalServerSupervisor.stop("autostart", org_id, project_id)
    end

    test "dispatches to running server", %{ctx: ctx} do
      Arca.McpServerStorage.put(ctx, %{
        name: "dispatch-test",
        url: "https://localhost:99999/mcp"
      })

      org_id = ctx.org_id || ""
      project_id = ctx.project_id || "default"

      # Pre-start the server
      Emissary.MCP.ExternalServerSupervisor.ensure_started(
        name: "dispatch-test",
        url: "https://localhost:99999/mcp",
        org_id: org_id,
        project_id: project_id
      )

      # try_handle should dispatch (will fail at HTTP level, but not :not_external)
      assert {:error, msg} = ExternalProvider.try_handle("dispatch-test:tool", ctx, %{})
      refute msg == :not_external

      # Cleanup
      Emissary.MCP.ExternalServerSupervisor.stop("dispatch-test", org_id, project_id)
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
