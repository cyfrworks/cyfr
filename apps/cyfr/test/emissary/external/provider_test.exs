# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.External.ProviderTest do
  use ExUnit.Case, async: false

  alias Emissary.External.Provider

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    ctx = Sanctum.TestContext.local()
    {:ok, ctx: ctx}
  end

  describe "tools/0" do
    test "returns mcp_servers tool definition" do
      tools = Provider.tools()
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
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "config" => %{"url" => "https://example.com/mcp"}
               })
    end

    test "requires config.url", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Missing required parameter: config.url"}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "name" => "test",
                 "config" => %{}
               })
    end

    test "validates url format", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Invalid URL:" <> _}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "name" => "test",
                 "config" => %{"url" => "not-a-url"}
               })
    end

    test "rejects name containing colon", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Server name cannot contain ':'" <> _}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "name" => "foo:bar",
                 "config" => %{"url" => "https://example.com/mcp"}
               })
    end

    test "rejects SSRF URLs targeting metadata endpoints", %{ctx: ctx} do
      # In `:platform` mode, private IPs should be blocked
      result =
        Provider.handle("mcp_servers", ctx, %{
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
      Provider.handle("mcp_servers", ctx, %{
        "action" => "create",
        "name" => "limit-s1",
        "config" => %{"url" => "https://localhost:99999/mcp"}
      })

      Provider.handle("mcp_servers", ctx, %{
        "action" => "create",
        "name" => "limit-s2",
        "config" => %{"url" => "https://localhost:99999/mcp"}
      })

      # Third should be rejected
      assert {:error, "Maximum server limit (2) reached"} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "name" => "limit-s3",
                 "config" => %{"url" => "https://localhost:99999/mcp"}
               })
    end

    test "saves server config to storage and answers the row's id", %{ctx: ctx} do
      # The actual HTTP connection will fail, but the config should be saved
      result =
        Provider.handle("mcp_servers", ctx, %{
          "action" => "create",
          "name" => "test-save",
          "config" => %{"url" => "https://localhost:99999/mcp"}
        })

      assert {:ok, %{name: "test-save", id: id, transport: "http", epoch: 1}} = result

      # Verify it was persisted
      assert {:ok, server} = Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "test-save")
      assert server.id == id
      assert server.url == "https://localhost:99999/mcp"
    end
  end

  describe "handle/3 - create and update" do
    setup %{ctx: ctx} do
      on_exit(fn ->
        for name <- ["kept", "absent"],
            do: Emissary.External.ServerSupervisor.stop(name, ctx.athanor_id)
      end)
    end

    test "create refuses a name in use; update replaces the config and keeps it disabled",
         %{ctx: ctx} do
      assert {:ok, %{name: "kept"}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "name" => "kept",
                 "config" => %{"url" => "https://localhost:99999/mcp"}
               })

      {:ok, %{id: id}} = Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "kept")

      assert {:error, {:conflict, message}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "name" => "kept",
                 "config" => %{"url" => "https://localhost:99998/mcp"}
               })

      assert message =~ "update"

      assert {:ok, %{url: "https://localhost:99999/mcp"}} =
               Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "kept")

      assert {:ok, _} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "disable",
                 "name" => "kept"
               })

      {:ok, %{epoch: epoch}} = Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "kept")

      assert {:ok, %{status: "disabled", epoch: new_epoch}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "update",
                 "name" => "kept",
                 "epoch" => epoch,
                 "config" => %{"url" => "https://localhost:99998/mcp", "timeout_ms" => 5_000}
               })

      assert new_epoch == epoch + 1
      assert {:ok, server} = Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "kept")
      assert server.id == id
      assert server.url == "https://localhost:99998/mcp"
      assert server.enabled == false
      assert Jason.decode!(server.config_json)["timeout_ms"] == 5_000
    end

    test "update names the epoch it read, and is refused once the server has moved on",
         %{ctx: ctx} do
      {:ok, %{epoch: epoch}} =
        Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
          name: "kept",
          url: "https://localhost:99999/mcp"
        })

      update = fn args ->
        Provider.handle(
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
        Provider.handle("mcp_servers", ctx, %{"action" => "disable", "name" => "kept"})

      assert {:error, {:conflict, message}} = update.(%{"epoch" => epoch})
      assert message =~ "changed since epoch #{epoch}"

      assert {:ok, %{url: "https://localhost:99999/mcp"}} =
               Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "kept")
    end

    test "update validates like create and finds only a server that exists", %{ctx: ctx} do
      assert {:error, {:not_found, "Server", "absent"}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "update",
                 "name" => "absent",
                 "epoch" => 1,
                 "config" => %{"url" => "https://localhost:99999/mcp"}
               })

      assert {:error, {:invalid_argument, "Invalid URL:" <> _}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "update",
                 "name" => "absent",
                 "epoch" => 1,
                 "config" => %{"url" => "http://169.254.169.254/latest/meta-data/"}
               })
    end
  end

  describe "handle/3 - a header's vault entry and the server's URL" do
    @header_refusal "Header 'Authorization' names no active vault entry whose destination " <>
                      "covers this server's URL"

    setup %{ctx: ctx} do
      on_exit(fn ->
        for name <- ["relay", "local", "kept"],
            do: Emissary.External.ServerSupervisor.stop(name, ctx.athanor_id)
      end)

      {:ok, openai} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "openai-key",
          kind: "api_key",
          fields: %{"token" => "sk-openai-0123456789"},
          destination: %{"hosts" => ["api.openai.com"], "paths" => ["/v1"]}
        })

      {:ok, local} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "local-key",
          kind: "api_key",
          fields: %{"token" => "sk-local-0123456789"},
          destination: %{"hosts" => ["127.0.0.1"], "port" => 9}
        })

      {:ok, openai: openai, local: local}
    end

    defp http(url, header), do: %{"url" => url, "headers" => %{"Authorization" => header}}

    defp define(ctx, action, name, config, extra \\ %{}) do
      Provider.handle(
        "mcp_servers",
        ctx,
        Map.merge(%{"action" => action, "name" => name, "config" => config}, extra)
      )
    end

    defp last_used_at(ctx, entry) do
      {:ok, row} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), entry.id)
      row.last_used_at
    end

    test "an external definition cannot send an entry outside its destination",
         %{ctx: ctx, openai: openai} do
      actor = Sanctum.Context.actor(ctx)

      # Another host, the entry's host outside its paths, and an entry that
      # is not there: the one refusal, naming the header and never the entry.
      for config <- [
            http("https://evil.example/mcp", "vault:openai-key"),
            http("https://evil.example/mcp", "Bearer vault:openai-key"),
            http("https://api.openai.com/v2/mcp", "vault:openai-key"),
            http("https://evil.example/mcp", "vault:no-such-key")
          ] do
        assert {:error, {:invalid_argument, @header_refusal}} =
                 define(ctx, "create", "relay", config),
               inspect(config)
      end

      assert {:error, :not_found} = Arca.McpServerStorage.get(actor, "relay")

      # An update is held to the same rule, and leaves the row as it was.
      {:ok, kept} =
        Arca.McpServerStorage.insert(actor, %{
          name: "kept",
          url: "https://127.0.0.1:9/mcp",
          enabled: false,
          config_json: Jason.encode!(%{"headers" => %{"Authorization" => "vault:local-key"}})
        })

      assert {:error, {:invalid_argument, @header_refusal}} =
               define(
                 ctx,
                 "update",
                 "kept",
                 http("https://evil.example/mcp", "vault:openai-key"),
                 %{"epoch" => kept.epoch}
               )

      assert {:ok, %{url: "https://127.0.0.1:9/mcp", epoch: epoch}} =
               Arca.McpServerStorage.get(actor, "kept")

      assert epoch == kept.epoch

      # A row edited underneath to send the entry elsewhere connects to
      # nothing: the connect refuses in the reader's words, unsealed.
      {:ok, _} =
        Arca.McpServerStorage.update(actor, "kept", %{
          url: "https://evil.example/mcp",
          enabled: true,
          config_json: Jason.encode!(%{"headers" => %{"Authorization" => "vault:openai-key"}})
        })

      assert {:ok, %{status: "error", error: sentence}} =
               Provider.handle("mcp_servers", ctx, %{"action" => "test", "name" => "kept"})

      assert sentence == Grimoire.render(:destination_mismatch)
      refute sentence =~ "openai-key"
      assert last_used_at(ctx, openai) == nil
    end

    test "an entry whose destination covers the URL is admitted", %{ctx: ctx, local: local} do
      # Saved, and the connect resolved the header before the upstream
      # refused the connection.
      assert {:ok, %{name: "local", status: "error"}} =
               define(ctx, "create", "local", http("https://127.0.0.1:9/mcp", "vault:local-key"))

      assert {:ok, _} = Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "local")
      assert %DateTime{} = last_used_at(ctx, local)
    end

    test "a wildcard host admits a name below it, and the URL is validated next", %{ctx: ctx} do
      {:ok, _} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "wild-key",
          kind: "api_key",
          fields: %{"token" => "sk-wild-0123456789"},
          destination: %{"hosts" => ["*.example.invalid"]}
        })

      # Past the header's check, the URL itself is what refuses: `.invalid`
      # never resolves.
      assert {:error, {:invalid_argument, "Invalid URL:" <> _}} =
               define(
                 ctx,
                 "create",
                 "relay",
                 http("https://mcp.example.invalid/mcp", "vault:wild-key")
               )

      assert {:error, {:invalid_argument, @header_refusal}} =
               define(
                 ctx,
                 "create",
                 "relay",
                 http("https://example.invalid/mcp", "vault:wild-key")
               )
    end

    test "an inactive entry is refused like a missing one", %{ctx: ctx, local: local} do
      {:ok, _} = Sanctum.Vault.revoke(ctx, local.id)

      assert {:error, {:invalid_argument, @header_refusal}} =
               define(ctx, "create", "local", http("https://127.0.0.1:9/mcp", "vault:local-key"))
    end
  end

  describe "handle/3 - an upstream that echoes the header it was sent" do
    @echoed "sk-echo-provider-0123456789"

    setup %{ctx: ctx} do
      bypass = Bypass.open()

      {:ok, _} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "echo-key",
          kind: "api_key",
          fields: %{"token" => @echoed},
          destination: %{"hosts" => ["127.0.0.1"], "scheme" => "http", "port" => bypass.port}
        })

      on_exit(fn -> Emissary.External.ServerSupervisor.stop("echo", ctx.athanor_id) end)
      {:ok, bypass: bypass, url: "http://127.0.0.1:#{bypass.port}/mcp"}
    end

    for era <- [:modern, :legacy] do
      test "create, Test and Refresh answer the mask, never the value (#{era} peer)", %{
        ctx: ctx,
        bypass: bypass,
        url: url
      } do
        echo_upstream(bypass, unquote(era))
        masked = "rejected credential [REDACTED]"

        assert {:ok, %{name: "echo", status: "error", error: ^masked} = created} =
                 Provider.handle("mcp_servers", ctx, %{
                   "action" => "create",
                   "name" => "echo",
                   "config" => %{
                     "url" => url,
                     "headers" => %{"Authorization" => "Bearer vault:echo-key"}
                   }
                 })

        assert {:ok, %{status: "error", error: ^masked} = tested} =
                 Provider.handle("mcp_servers", ctx, %{"action" => "test", "name" => "echo"})

        assert {:error, refreshed} =
                 Provider.handle("mcp_servers", ctx, %{"action" => "refresh", "name" => "echo"})

        assert refreshed == "Failed to refresh echo: " <> masked

        assert {:ok, %{refreshed: [], failed: [%{name: "echo", error: every}]}} =
                 Provider.handle("mcp_servers", ctx, %{"action" => "refresh"})

        assert every =~ "rejected credential"
        refute inspect({created, tested, refreshed, every}) =~ @echoed
      end
    end

    # An upstream that refuses the connect with an error quoting the
    # Authorization header it was sent: at `tools/list` for a current peer,
    # and at `initialize` for one that answers the current probe as a
    # legacy peer does.
    defp echo_upstream(bypass, era) do
      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        [auth] = Plug.Conn.get_req_header(conn, "authorization")

        case {era, request["method"]} do
          {:legacy, "tools/list"} ->
            Plug.Conn.resp(conn, 400, "Bad Request")

          _echoed ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(
              200,
              Jason.encode!(%{
                "jsonrpc" => "2.0",
                "id" => request["id"],
                "error" => %{"code" => -32001, "message" => "rejected credential #{auth}"}
              })
            )
        end
      end)
    end
  end

  describe "handle/3 - stdio servers" do
    # The entry the backends' env reads, disclosed: an environment hands it
    # to the process it starts.
    setup %{ctx: ctx} do
      {:ok, _} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "gh-token",
          kind: "api_key",
          fields: %{"token" => "ghp_provider_test_0123456789"},
          destination: %{"hosts" => ["api.github.com"]},
          disclose: true
        })

      :ok
    end

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

    test "are refused while no backends service is configured", %{ctx: ctx} do
      refute Emissary.External.Backends.running?()

      assert {:error, {:invalid_argument, message}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "create",
                 "name" => "piped",
                 "config" => @stdio_config
               })

      assert message =~ "CYFR_LOCUS_BACKENDS_KEY"
      assert {:error, :not_found} = Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "piped")
    end

    test "carry no url or headers, and their backends are validated", %{ctx: ctx} do
      for {config, fragment} <- [
            {Map.put(@stdio_config, "url", "https://x/mcp"), "no url"},
            {Map.put(@stdio_config, "headers", %{}), "no headers"},
            {%{"url" => "https://x/mcp", "backends" => []}, "no backends"},
            {Map.put(@stdio_config, "transport", "ws"), "Unknown transport"}
          ] do
        assert {:error, {:invalid_argument, message}} =
                 Provider.handle("mcp_servers", ctx, %{
                   "action" => "create",
                   "name" => "piped",
                   "config" => config
                 })

        assert message =~ fragment
      end
    end

    test "restart is for an enabled stdio server only", %{ctx: ctx} do
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "webby",
        url: "https://x.com/mcp"
      })

      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "sleepy",
        transport: "stdio",
        url: nil,
        enabled: false,
        config_json: Jason.encode!(@stdio_config)
      })

      assert {:error, {:invalid_argument, "Only a stdio server restarts" <> _}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "restart",
                 "name" => "webby"
               })

      assert {:error, {:invalid_argument, "Server 'sleepy' is disabled" <> _}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "restart",
                 "name" => "sleepy"
               })

      assert {:error, {:not_found, "Server", "nobody"}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "restart",
                 "name" => "nobody"
               })
    end

    test "list names the transport and the vault entries the env reads", %{ctx: ctx} do
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "listed",
        transport: "stdio",
        url: nil,
        config_json: Jason.encode!(@stdio_config)
      })

      assert {:ok, %{servers: [server]}} =
               Provider.handle("mcp_servers", ctx, %{"action" => "list"})

      assert %{name: "listed", transport: "stdio", url: nil, vault_refs: ["gh-token"]} = server
    end
  end

  describe "handle/3 - delete" do
    test "requires name", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Missing required parameter: name"}} =
               Provider.handle("mcp_servers", ctx, %{"action" => "delete"})
    end

    test "deletes existing server", %{ctx: ctx} do
      {:ok, %{id: id}} =
        Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
          name: "to-delete",
          url: "https://x.com/mcp"
        })

      assert {:ok, %{deleted: "to-delete", id: ^id}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "delete",
                 "name" => "to-delete"
               })

      assert {:error, :not_found} =
               Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "to-delete")

      assert {:error, {:not_found, "Server", "to-delete"}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "delete",
                 "name" => "to-delete"
               })
    end
  end

  describe "handle/3 - list" do
    test "returns empty list when no servers configured", %{ctx: ctx} do
      assert {:ok, %{servers: [], count: 0}} =
               Provider.handle("mcp_servers", ctx, %{"action" => "list"})
    end

    test "returns configured servers", %{ctx: ctx} do
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "s1",
        url: "https://a.com/mcp"
      })

      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "s2",
        url: "https://b.com/mcp"
      })

      assert {:ok, %{servers: servers, count: 2}} =
               Provider.handle("mcp_servers", ctx, %{"action" => "list"})

      names = Enum.map(servers, & &1.name)
      assert "s1" in names
      assert "s2" in names
    end

    test "listing starts no server processes", %{ctx: ctx} do
      # Listing servers must not start processes or open outbound connections.
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "lazy-1",
        url: "https://a.com/mcp",
        enabled: true
      })

      assert {:ok, %{servers: [server]}} =
               Provider.handle("mcp_servers", ctx, %{"action" => "list"})

      assert server.status == "disconnected"

      assert Registry.lookup(
               Emissary.External.ServerRegistry,
               {"lazy-1", ctx.athanor_id}
             ) == []
    end

    test "list and get are not in-chain reachable" do
      [tool] = Provider.tools()

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
      Provider.handle("mcp_servers", ctx, %{
        "action" => "create",
        "name" => "hdr-redact",
        "config" => %{
          "url" => "https://localhost:99999/mcp",
          "headers" => %{"x-hub" => "super-secret-literal", "x-plain" => "not-a-secret"}
        }
      })

      assert {:ok, %{config: config}} =
               Provider.handle("mcp_servers", ctx, %{
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
      for name <- ["my_entry", "other_entry"] do
        {:ok, _} =
          Sanctum.TestContext.create_vault(ctx, %{
            name: name,
            kind: "api_key",
            fields: %{"token" => "t-" <> name},
            destination: %{"hosts" => ["127.0.0.1"], "port" => 9}
          })
      end

      on_exit(fn -> Emissary.External.ServerSupervisor.stop("hdr-vault", ctx.athanor_id) end)

      {:ok, _} =
        Provider.handle("mcp_servers", ctx, %{
          "action" => "create",
          "name" => "hdr-vault",
          "config" => %{
            "url" => "https://127.0.0.1:9/mcp",
            "headers" => %{
              "authorization" => "Bearer vault:my_entry",
              "x-api-key" => "vault:other_entry"
            }
          }
        })

      assert {:ok, %{config: config}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "get",
                 "name" => "hdr-vault"
               })

      assert config["headers"]["authorization"] == "Bearer vault:my_entry"
      assert config["headers"]["x-api-key"] == "vault:other_entry"
    end
  end

  describe "handle/3 - create refuses a literal credential" do
    test "in every header Prima names a credential carrier, in any case", %{ctx: ctx} do
      names = Prima.Network.credential_headers() ++ ["X-API-Key", "Cookie", "X-Client-Secret"]

      for name <- names do
        assert {:error, reason} =
                 Provider.handle("mcp_servers", ctx, %{
                   "action" => "create",
                   "name" => "hdr-literal",
                   "config" => %{
                     "url" => "https://localhost:99999/mcp",
                     "headers" => %{name => "literal-credential"}
                   }
                 }),
               name

        assert inspect(reason) =~ "looks like a credential", name
        refute inspect(reason) =~ "literal-credential"
      end
    end
  end

  describe "handle/3 - a disabled server" do
    test "is neither tested nor refreshed by name, and a refresh of all skips it", %{ctx: ctx} do
      {:ok, _} =
        Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
          name: "dormant",
          url: "https://127.0.0.1:9/mcp",
          enabled: false,
          config_json: Jason.encode!(%{"headers" => %{}, "timeout_ms" => 1_000})
        })

      for action <- ["test", "refresh"] do
        assert {:error, {:invalid_argument, message}} =
                 Provider.handle("mcp_servers", ctx, %{
                   "action" => action,
                   "name" => "dormant"
                 })

        assert message =~ "disabled"
      end

      assert {:ok, %{refreshed: refreshed, failed: failed}} =
               Provider.handle("mcp_servers", ctx, %{"action" => "refresh"})

      refute "dormant" in refreshed
      refute Enum.any?(failed, &(&1.name == "dormant"))

      assert Registry.lookup(Emissary.External.ServerRegistry, {"dormant", ctx.athanor_id}) ==
               []
    end
  end

  describe "the stored row" do
    test "insert and update answer the row they wrote", %{ctx: ctx} do
      assert {:ok, %{id: "mcp_" <> _ = id, name: "rowsrv", enabled: true}} =
               Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
                 name: "rowsrv",
                 url: "https://127.0.0.1:9/mcp"
               })

      assert {:ok, %{id: ^id, enabled: false}} =
               Arca.McpServerStorage.update(Sanctum.Context.actor(ctx), "rowsrv", %{
                 enabled: false
               })

      assert {:error, :exists} =
               Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
                 name: "rowsrv",
                 url: "https://127.0.0.1:9/mcp"
               })

      assert {:error, :not_found} =
               Arca.McpServerStorage.update(Sanctum.Context.actor(ctx), "nosuch", %{enabled: true})
    end

    test "a row deleted and recreated under its name is served by a new process", %{ctx: ctx} do
      attrs = %{name: "reborn", url: "https://127.0.0.1:9/mcp"}
      {:ok, first} = Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), attrs)
      config = Emissary.External.Servers.server_config(first, ctx)
      {:ok, old_pid} = Emissary.External.ServerSupervisor.ensure_started(config)

      {:ok, _} = Arca.McpServerStorage.delete(Sanctum.Context.actor(ctx), "reborn")
      {:ok, second} = Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), attrs)
      refute second.id == first.id

      {:ok, new_pid} =
        Emissary.External.ServerSupervisor.ensure_started(
          Emissary.External.Servers.server_config(second, ctx)
        )

      refute new_pid == old_pid
      refute Process.alive?(old_pid)
      Emissary.External.ServerSupervisor.stop("reborn", ctx.athanor_id)
    end
  end

  describe "handle/3 - get" do
    test "requires name", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Missing required parameter: name"}} =
               Provider.handle("mcp_servers", ctx, %{"action" => "get"})
    end

    test "requires non-empty name", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Missing required parameter: name"}} =
               Provider.handle("mcp_servers", ctx, %{"action" => "get", "name" => ""})
    end

    test "returns error for non-existent server", %{ctx: ctx} do
      assert {:error, {:not_found, "Server", "nonexistent"}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "get",
                 "name" => "nonexistent"
               })
    end

    test "returns server details for existing server", %{ctx: ctx} do
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "get-test",
        url: "https://x.com/mcp"
      })

      assert {:ok, %{name: "get-test", url: "https://x.com/mcp"}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "get",
                 "name" => "get-test"
               })
    end
  end

  describe "handle/3 - test" do
    test "requires name", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Missing required parameter: name"}} =
               Provider.handle("mcp_servers", ctx, %{"action" => "test"})
    end

    test "requires non-empty name", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Missing required parameter: name"}} =
               Provider.handle("mcp_servers", ctx, %{"action" => "test", "name" => ""})
    end

    test "returns error for non-existent server", %{ctx: ctx} do
      assert {:error, {:not_found, "Server", "nonexistent"}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "test",
                 "name" => "nonexistent"
               })
    end

    test "returns status for existing server", %{ctx: ctx} do
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "test-srv",
        url: "https://localhost:99999/mcp"
      })

      # Will fail to connect but should return a status result, not a not_found error
      assert {:ok, %{name: "test-srv"}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "test",
                 "name" => "test-srv"
               })
    end
  end

  describe "handle/3 - refresh" do
    test "returns error for non-existent named server", %{ctx: ctx} do
      assert {:error, {:not_found, "Server", "nonexistent"}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "refresh",
                 "name" => "nonexistent"
               })
    end

    test "refreshes all servers when no name given", %{ctx: ctx} do
      # With no servers, should return empty results
      assert {:ok, %{refreshed: [], failed: []}} =
               Provider.handle("mcp_servers", ctx, %{"action" => "refresh"})
    end

    test "refreshes all servers with empty name", %{ctx: ctx} do
      assert {:ok, %{refreshed: _, failed: _}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "refresh",
                 "name" => ""
               })
    end
  end

  describe "handle/3 - enable/disable" do
    test "disables a server", %{ctx: ctx} do
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "toggle",
        url: "https://x.com/mcp"
      })

      assert {:ok, %{enabled: false}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "disable",
                 "name" => "toggle"
               })

      assert {:ok, server} = Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "toggle")
      assert server.enabled == false
    end

    test "enables a disabled server", %{ctx: ctx} do
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "toggle2",
        url: "https://x.com/mcp",
        enabled: false
      })

      assert {:ok, %{enabled: true}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "enable",
                 "name" => "toggle2"
               })
    end
  end

  describe "handle/3 - unknown" do
    test "returns error for unknown action", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Unknown action: " <> _}} =
               Provider.handle("mcp_servers", ctx, %{"action" => "bogus"})
    end

    test "returns error for missing action", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Missing required parameter: action"}} =
               Provider.handle("mcp_servers", ctx, %{})
    end

    test "returns error for unknown tool", %{ctx: ctx} do
      assert {:error, "Unknown tool: other"} =
               Provider.handle("other", ctx, %{"action" => "list"})
    end
  end
end
