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
      assert "update" in actions
      assert "delete" in actions
      assert "list" in actions
      assert "get" in actions
      assert "test" in actions
      assert "refresh" in actions
      assert "enable" in actions
      assert "disable" in actions
      assert "restart" in actions
    end
  end

  describe "handle/3 - create" do
    test "requires name", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Missing required parameter: name"}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "config" => %{"url" => "https://example.com/mcp"}
               })
    end

    test "requires config.url", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Missing required parameter: config.url"}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "name" => "test",
                 "config" => %{}
               })
    end

    test "validates url format", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Invalid URL:" <> _}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "name" => "test",
                 "config" => %{"url" => "not-a-url"}
               })
    end

    test "rejects name containing colon", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Server name cannot contain ':'" <> _}} =
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

      assert {:error, {:invalid_argument, "Invalid URL:" <> _}} = result
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

    test "saves server config to storage and answers the row's id", %{ctx: ctx} do
      # The actual HTTP connection will fail, but the config should be saved
      result =
        McpServersTool.handle("mcp_servers", ctx, %{
          "action" => "create",
          "name" => "test-save",
          "config" => %{"url" => "https://localhost:99999/mcp"}
        })

      assert {:ok, %{name: "test-save", id: id, transport: "http", epoch: 1}} = result

      # Verify it was persisted
      assert {:ok, server} = Arca.McpServerStorage.get(ctx, "test-save")
      assert server.id == id
      assert server.url == "https://localhost:99999/mcp"
    end
  end

  describe "handle/3 - create and update" do
    setup %{ctx: ctx} do
      on_exit(fn ->
        for name <- ["kept", "absent"],
            do: Emissary.MCP.ExternalServerSupervisor.stop(name, ctx.athanor_id)
      end)
    end

    test "create refuses a name in use; update replaces the config and keeps it disabled",
         %{ctx: ctx} do
      assert {:ok, %{name: "kept"}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "name" => "kept",
                 "config" => %{"url" => "https://localhost:99999/mcp"}
               })

      {:ok, %{id: id}} = Arca.McpServerStorage.get(ctx, "kept")

      assert {:error, {:conflict, message}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "name" => "kept",
                 "config" => %{"url" => "https://localhost:99998/mcp"}
               })

      assert message =~ "update"
      assert {:ok, %{url: "https://localhost:99999/mcp"}} = Arca.McpServerStorage.get(ctx, "kept")

      assert {:ok, _} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "disable",
                 "name" => "kept"
               })

      {:ok, %{epoch: epoch}} = Arca.McpServerStorage.get(ctx, "kept")

      assert {:ok, %{status: "disabled", epoch: new_epoch}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "update",
                 "name" => "kept",
                 "epoch" => epoch,
                 "config" => %{"url" => "https://localhost:99998/mcp", "timeout_ms" => 5_000}
               })

      assert new_epoch == epoch + 1
      assert {:ok, server} = Arca.McpServerStorage.get(ctx, "kept")
      assert server.id == id
      assert server.url == "https://localhost:99998/mcp"
      assert server.enabled == false
      assert Jason.decode!(server.config_json)["timeout_ms"] == 5_000
    end

    test "update names the epoch it read, and is refused once the server has moved on",
         %{ctx: ctx} do
      {:ok, %{epoch: epoch}} =
        Arca.McpServerStorage.insert(ctx, %{name: "kept", url: "https://localhost:99999/mcp"})

      update = fn args ->
        McpServersTool.handle(
          "mcp_servers",
          ctx,
          Map.merge(
            %{
              "action" => "update",
              "name" => "kept",
              "config" => %{"url" => "https://localhost:99997/mcp"}
            },
            args
          )
        )
      end

      assert {:error, {:invalid_argument, "Missing required parameter: epoch" <> _}} =
               update.(%{})

      {:ok, _} =
        McpServersTool.handle("mcp_servers", ctx, %{"action" => "disable", "name" => "kept"})

      assert {:error, {:conflict, message}} = update.(%{"epoch" => epoch})
      assert message =~ "changed since epoch #{epoch}"
      assert {:ok, %{url: "https://localhost:99999/mcp"}} = Arca.McpServerStorage.get(ctx, "kept")
    end

    test "update validates like create and finds only a server that exists", %{ctx: ctx} do
      assert {:error, {:not_found, "Server", "absent"}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "update",
                 "name" => "absent",
                 "epoch" => 1,
                 "config" => %{"url" => "https://localhost:99999/mcp"}
               })

      assert {:error, {:invalid_argument, "Invalid URL:" <> _}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "update",
                 "name" => "absent",
                 "epoch" => 1,
                 "config" => %{"url" => "http://169.254.169.254/latest/meta-data/"}
               })
    end
  end

  describe "handle/3 - stdio servers" do
    @stdio_config %{
      "transport" => "stdio",
      "backends" => [
        %{
          "name" => "github",
          "command" => "npx -y @modelcontextprotocol/server-github",
          "env" => %{"GITHUB_PERSONAL_ACCESS_TOKEN" => "vault:gh-token"}
        }
      ]
    }

    test "are refused while no MCP bridge is configured", %{ctx: ctx} do
      refute Emissary.MCP.Bridge.running?()

      assert {:error, {:invalid_argument, message}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "name" => "piped",
                 "config" => @stdio_config
               })

      assert message =~ "CYFR_MCP_BRIDGE_KEY"
      assert {:error, :not_found} = Arca.McpServerStorage.get(ctx, "piped")
    end

    test "carry no url or headers, and their backends are validated", %{ctx: ctx} do
      for {config, fragment} <- [
            {Map.put(@stdio_config, "url", "https://x/mcp"), "no url"},
            {Map.put(@stdio_config, "headers", %{}), "no headers"},
            {%{"url" => "https://x/mcp", "backends" => []}, "no backends"},
            {Map.put(@stdio_config, "transport", "ws"), "Unknown transport"}
          ] do
        assert {:error, {:invalid_argument, message}} =
                 McpServersTool.handle("mcp_servers", ctx, %{
                   "action" => "create",
                   "name" => "piped",
                   "config" => config
                 })

        assert message =~ fragment
      end
    end

    test "restart is for an enabled stdio server only", %{ctx: ctx} do
      Arca.McpServerStorage.insert(ctx, %{name: "webby", url: "https://x.com/mcp"})

      Arca.McpServerStorage.insert(ctx, %{
        name: "sleepy",
        transport: "stdio",
        url: nil,
        enabled: false,
        config_json: Jason.encode!(@stdio_config)
      })

      assert {:error, {:invalid_argument, "Only a stdio server restarts" <> _}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "restart",
                 "name" => "webby"
               })

      assert {:error, {:invalid_argument, "Server 'sleepy' is disabled" <> _}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "restart",
                 "name" => "sleepy"
               })

      assert {:error, {:not_found, "Server", "nobody"}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "restart",
                 "name" => "nobody"
               })
    end

    test "list names the transport and the vault entries the env reads", %{ctx: ctx} do
      Arca.McpServerStorage.insert(ctx, %{
        name: "listed",
        transport: "stdio",
        url: nil,
        config_json: Jason.encode!(@stdio_config)
      })

      assert {:ok, %{servers: [server]}} =
               McpServersTool.handle("mcp_servers", ctx, %{"action" => "list"})

      assert %{name: "listed", transport: "stdio", url: nil, vault_refs: ["gh-token"]} = server
    end
  end

  describe "handle/3 - delete" do
    test "requires name", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Missing required parameter: name"}} =
               McpServersTool.handle("mcp_servers", ctx, %{"action" => "delete"})
    end

    test "deletes existing server", %{ctx: ctx} do
      {:ok, %{id: id}} =
        Arca.McpServerStorage.insert(ctx, %{name: "to-delete", url: "https://x.com/mcp"})

      assert {:ok, %{deleted: "to-delete", id: ^id}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "delete",
                 "name" => "to-delete"
               })

      assert {:error, :not_found} = Arca.McpServerStorage.get(ctx, "to-delete")

      assert {:error, {:not_found, "Server", "to-delete"}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "delete",
                 "name" => "to-delete"
               })
    end
  end

  describe "handle/3 - list" do
    test "returns empty list when no servers configured", %{ctx: ctx} do
      assert {:ok, %{servers: [], count: 0}} =
               McpServersTool.handle("mcp_servers", ctx, %{"action" => "list"})
    end

    test "returns configured servers", %{ctx: ctx} do
      Arca.McpServerStorage.insert(ctx, %{name: "s1", url: "https://a.com/mcp"})
      Arca.McpServerStorage.insert(ctx, %{name: "s2", url: "https://b.com/mcp"})

      assert {:ok, %{servers: servers, count: 2}} =
               McpServersTool.handle("mcp_servers", ctx, %{"action" => "list"})

      names = Enum.map(servers, & &1.name)
      assert "s1" in names
      assert "s2" in names
    end

    test "listing starts no server processes", %{ctx: ctx} do
      # Listing servers must not start processes or open outbound connections.
      Arca.McpServerStorage.insert(ctx, %{name: "lazy-1", url: "https://a.com/mcp", enabled: true})

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

  describe "handle/3 - get does not hand back stored header values" do
    # `config_json` is not encrypted, and create only refuses a literal in a
    # header whose NAME looks like a credential — a denylist that "x-hub"
    # and "x-signature" walk straight past. `get` is annotated read with no
    # permission, so anything stored there is readable by every member of
    # the athanor. Header names and vault binding names are the shared
    # operator infrastructure; the values are not.
    test "a literal header value is reported as set, never returned", %{ctx: ctx} do
      McpServersTool.handle("mcp_servers", ctx, %{
        "action" => "create",
        "name" => "hdr-redact",
        "config" => %{
          "url" => "https://localhost:99999/mcp",
          "headers" => %{"x-hub" => "super-secret-literal", "x-plain" => "not-a-secret"}
        }
      })

      assert {:ok, %{config: config}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "get",
                 "name" => "hdr-redact"
               })

      headers = config["headers"]

      # The names stay — they are how an operator sees the wiring.
      assert Map.keys(headers) |> Enum.sort() == ["x-hub", "x-plain"]

      assert headers["x-hub"] == "[set]"
      assert headers["x-plain"] == "[set]"
      refute inspect(config) =~ "super-secret-literal"
    end

    test "a vault reference is still shown — it names a vault entry", %{ctx: ctx} do
      McpServersTool.handle("mcp_servers", ctx, %{
        "action" => "create",
        "name" => "hdr-vault",
        "config" => %{
          "url" => "https://localhost:99999/mcp",
          "headers" => %{
            "authorization" => "Bearer vault:my_entry",
            "x-api-key" => "vault:other_entry"
          }
        }
      })

      assert {:ok, %{config: config}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "get",
                 "name" => "hdr-vault"
               })

      assert config["headers"]["authorization"] == "Bearer vault:my_entry"
      assert config["headers"]["x-api-key"] == "vault:other_entry"
    end
  end

  describe "handle/3 - a disabled server" do
    test "is neither tested nor refreshed by name, and a refresh of all skips it", %{ctx: ctx} do
      {:ok, _} =
        Arca.McpServerStorage.insert(ctx, %{
          name: "dormant",
          url: "https://127.0.0.1:9/mcp",
          enabled: false,
          config_json: Jason.encode!(%{"headers" => %{}, "timeout_ms" => 1_000})
        })

      for action <- ["test", "refresh"] do
        assert {:error, {:invalid_argument, message}} =
                 McpServersTool.handle("mcp_servers", ctx, %{
                   "action" => action,
                   "name" => "dormant"
                 })

        assert message =~ "disabled"
      end

      assert {:ok, %{refreshed: refreshed, failed: failed}} =
               McpServersTool.handle("mcp_servers", ctx, %{"action" => "refresh"})

      refute "dormant" in refreshed
      refute Enum.any?(failed, &(&1.name == "dormant"))

      assert Registry.lookup(Emissary.MCP.ExternalServerRegistry, {"dormant", ctx.athanor_id}) ==
               []
    end
  end

  describe "the stored row" do
    test "insert and update answer the row they wrote", %{ctx: ctx} do
      assert {:ok, %{id: "mcp_" <> _ = id, name: "rowsrv", enabled: true}} =
               Arca.McpServerStorage.insert(ctx, %{name: "rowsrv", url: "https://127.0.0.1:9/mcp"})

      assert {:ok, %{id: ^id, enabled: false}} =
               Arca.McpServerStorage.update(ctx, "rowsrv", %{enabled: false})

      assert {:error, :exists} =
               Arca.McpServerStorage.insert(ctx, %{name: "rowsrv", url: "https://127.0.0.1:9/mcp"})

      assert {:error, :not_found} = Arca.McpServerStorage.update(ctx, "nosuch", %{enabled: true})
    end

    test "a row deleted and recreated under its name is served by a new process", %{ctx: ctx} do
      attrs = %{name: "reborn", url: "https://127.0.0.1:9/mcp"}
      {:ok, first} = Arca.McpServerStorage.insert(ctx, attrs)
      config = Emissary.MCP.ExternalServers.server_config(first, ctx)
      {:ok, old_pid} = Emissary.MCP.ExternalServerSupervisor.ensure_started(config)

      {:ok, _} = Arca.McpServerStorage.delete(ctx, "reborn")
      {:ok, second} = Arca.McpServerStorage.insert(ctx, attrs)
      refute second.id == first.id

      {:ok, new_pid} =
        Emissary.MCP.ExternalServerSupervisor.ensure_started(
          Emissary.MCP.ExternalServers.server_config(second, ctx)
        )

      refute new_pid == old_pid
      refute Process.alive?(old_pid)
      Emissary.MCP.ExternalServerSupervisor.stop("reborn", ctx.athanor_id)
    end
  end

  describe "handle/3 - get" do
    test "requires name", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Missing required parameter: name"}} =
               McpServersTool.handle("mcp_servers", ctx, %{"action" => "get"})
    end

    test "requires non-empty name", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Missing required parameter: name"}} =
               McpServersTool.handle("mcp_servers", ctx, %{"action" => "get", "name" => ""})
    end

    test "returns error for non-existent server", %{ctx: ctx} do
      assert {:error, {:not_found, "Server", "nonexistent"}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "get",
                 "name" => "nonexistent"
               })
    end

    test "returns server details for existing server", %{ctx: ctx} do
      Arca.McpServerStorage.insert(ctx, %{name: "get-test", url: "https://x.com/mcp"})

      assert {:ok, %{name: "get-test", url: "https://x.com/mcp"}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "get",
                 "name" => "get-test"
               })
    end
  end

  describe "handle/3 - test" do
    test "requires name", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Missing required parameter: name"}} =
               McpServersTool.handle("mcp_servers", ctx, %{"action" => "test"})
    end

    test "requires non-empty name", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Missing required parameter: name"}} =
               McpServersTool.handle("mcp_servers", ctx, %{"action" => "test", "name" => ""})
    end

    test "returns error for non-existent server", %{ctx: ctx} do
      assert {:error, {:not_found, "Server", "nonexistent"}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "test",
                 "name" => "nonexistent"
               })
    end

    test "returns status for existing server", %{ctx: ctx} do
      Arca.McpServerStorage.insert(ctx, %{name: "test-srv", url: "https://localhost:99999/mcp"})

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
      assert {:error, {:not_found, "Server", "nonexistent"}} =
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
      Arca.McpServerStorage.insert(ctx, %{name: "toggle", url: "https://x.com/mcp"})

      assert {:ok, %{enabled: false}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "disable",
                 "name" => "toggle"
               })

      assert {:ok, server} = Arca.McpServerStorage.get(ctx, "toggle")
      assert server.enabled == false
    end

    test "enables a disabled server", %{ctx: ctx} do
      Arca.McpServerStorage.insert(ctx, %{
        name: "toggle2",
        url: "https://x.com/mcp",
        enabled: false
      })

      assert {:ok, %{enabled: true}} =
               McpServersTool.handle("mcp_servers", ctx, %{
                 "action" => "enable",
                 "name" => "toggle2"
               })
    end
  end

  describe "handle/3 - unknown" do
    test "returns error for unknown action", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Unknown action: " <> _}} =
               McpServersTool.handle("mcp_servers", ctx, %{"action" => "bogus"})
    end

    test "returns error for missing action", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Missing required parameter: action"}} =
               McpServersTool.handle("mcp_servers", ctx, %{})
    end

    test "returns error for unknown tool", %{ctx: ctx} do
      assert {:error, "Unknown tool: other"} =
               McpServersTool.handle("other", ctx, %{"action" => "list"})
    end
  end
end
