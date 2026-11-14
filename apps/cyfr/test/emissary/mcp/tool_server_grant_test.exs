# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ToolServerGrantTest do
  # A server grant authorizes only its matching configuration digest.
  # Changing the server configuration invalidates the grant; an unreachable
  # but authorized server returns an upstream error, not an authorization denial.
  use ExUnit.Case, async: false

  alias Prima.Authority
  alias Prima.Authority.Blob

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Arca.Cache.init()

    ctx = Sanctum.TestContext.local(:api)

    {:ok, server} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: "ghserver",
        url: "https://127.0.0.1:1/mcp",
        config_json:
          Jason.encode!(%{
            "headers" => %{},
            "timeout_ms" => 1_000,
            "tool_patterns" => ["issues.*", "repo_get"]
          })
      })

    on_exit(fn ->
      Arca.Cache.delete_match({:tool_server_digest, :_, :_})
    end)

    Arca.Cache.delete_match({:tool_server_digest, :_, :_})

    {:ok, digest} = Sanctum.ToolServerDigest.from_server(server)
    {:ok, ctx: ctx, digest: digest}
  end

  defp authority_with_server(digest, server \\ "ghserver") do
    node = "formula:local.mcp-consumer"

    graph = %{
      "canonical" => "jcs-1",
      "nodes" => %{
        node => %{
          "limits" => %{
            "timeout" => "1m",
            "max_memory_bytes" => 67_108_864,
            "max_request_size" => 1_048_576,
            "max_response_size" => 5_242_880,
            "rate_limit" => %{"requests" => 10_000, "window" => "1m"},
            "max_concurrent_tasks" => 10,
            "batch_timeout" => "1m"
          },
          "edges" => %{
            "@ingress" => %{
              "tools" => ["tools.list"],
              "tool_servers" => [
                %{
                  "server_digest" => digest,
                  "server_name" => server,
                  "tool_patterns" => ["issues.*"]
                }
              ]
            }
          }
        }
      }
    }

    {:ok, blob} = Blob.parse(graph)

    {:ok, auth} =
      Authority.root(
        %{
          profile_id: "prof-mcp",
          consent_id: "consent-mcp",
          source_ref: node,
          kind: :owner,
          invoke_mode: :open_inert,
          activation: %{node => "sha256:mcp"}
        },
        blob,
        ceiling: Sanctum.Policy.Ceiling.platform_ceiling()
      )

    auth
  end

  defp guest(ctx), do: Sanctum.Context.enter_guest(ctx)

  test "in-chain tools.list shows only granted external tools and in-chain internals",
       %{ctx: ctx, digest: digest} do
    auth = authority_with_server(digest)

    # Seed the discovery cache with three external tools: one covered by the
    # edge's grant (issues.*), one on the same server outside the patterns,
    # and one on an ungranted server. Only the first may be discovered.
    Arca.Cache.put(Arca.Cache.Keys.external_tools(Sanctum.Context.actor(ctx)), [
      %{"name" => "ghserver:issues.list", "description" => "granted", "inputSchema" => %{}},
      %{"name" => "ghserver:repo_get", "description" => "outside patterns", "inputSchema" => %{}},
      %{"name" => "othersrv:anything", "description" => "no grant", "inputSchema" => %{}}
    ])

    on_exit(fn -> Arca.Cache.delete_match({:external_tools, :_}) end)

    {:ok, %{tools: tools}} =
      Sanctum.Gate.call_in_chain("tools", guest(ctx), %{"action" => "list"}, auth,
        lineage: Cyfr.Test.AttemptFixtures.lineage!(guest(ctx))
      )

    names = Enum.map(tools, & &1["name"])

    assert "ghserver:issues.list" in names
    refute "ghserver:repo_get" in names
    refute "othersrv:anything" in names

    # Internal tools survive only where the authority grants them: this
    # edge grants tools.list alone, so the catalogue holds `tools` pruned
    # to ["list"] and no other internal tool.
    internal = Enum.reject(tools, &String.contains?(&1["name"], ":"))
    assert Enum.map(internal, & &1["name"]) == ["tools"]

    assert [%{"inputSchema" => %{"properties" => %{"action" => %{"enum" => ["list"]}}}}] =
             internal
  end

  test "the internal catalogue advertises exactly what the transition allows",
       %{ctx: ctx, digest: digest} do
    auth = authority_with_server(digest)

    {:ok, %{tools: tools}} =
      Sanctum.Gate.call_in_chain("tools", guest(ctx), %{"action" => "list"}, auth,
        lineage: Cyfr.Test.AttemptFixtures.lineage!(guest(ctx))
      )

    internal = Enum.reject(tools, &String.contains?(&1["name"], ":"))

    advertised =
      for t <- internal,
          a <- get_in(t, ["inputSchema", "properties", "action", "enum"]) || [],
          do: {t["name"], a}

    # Everything advertised is allowed at call time.
    for {name, action} <- advertised do
      assert {:allow_tool, _} =
               Prima.Authority.Transition.step(
                 auth,
                 :call,
                 {:tool, %{tool: name, action: action}}
               ),
             "#{name}.#{action} advertised but denied at call time"
    end

    # Everything in-chain-planed but ungranted was pruned, and a call
    # would be denied — the catalogue and the verdict are one fact.
    for tool_def <- Sanctum.Catalog.list_tools(),
        name = tool_def["name"],
        not String.contains?(name, ":"),
        action <- get_in(tool_def, ["inputSchema", "properties", "action", "enum"]) || [],
        :in_chain in Sanctum.Annotations.planes(tool_def, action),
        {name, action} not in advertised do
      assert {:deny, :tool_not_granted} =
               Prima.Authority.Transition.step(
                 auth,
                 :call,
                 {:tool, %{tool: name, action: action}}
               )
    end
  end

  test "a granted server's matching tool passes the transition", %{ctx: ctx, digest: digest} do
    auth = authority_with_server(digest)

    {:error, reason} =
      Sanctum.Gate.call_in_chain("ghserver:issues.list", guest(ctx), %{}, auth,
        lineage: Cyfr.Test.AttemptFixtures.lineage!(guest(ctx))
      )

    # It got PAST the authority — the failure is the unreachable upstream,
    # which the proxy hands back classified rather than as a bare sentence.
    refute is_binary(reason)
    refute match?(%Prima.Refusal{stage: :admission}, reason)
    refute Sanctum.Refusals.render(reason) =~ "Denied by chain authority"
  end

  test "a tool outside the granted patterns is not callable", %{ctx: ctx, digest: digest} do
    auth = authority_with_server(digest)

    {:error, %Prima.Refusal{stage: :admission, message: message}} =
      Sanctum.Gate.call_in_chain("ghserver:repo_get", guest(ctx), %{}, auth,
        lineage: Cyfr.Test.AttemptFixtures.lineage!(guest(ctx))
      )

    assert message =~ "Denied by chain authority"
  end

  test "one server's grant never authorizes another", %{ctx: ctx, digest: digest} do
    {:ok, _other} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: "othersrv",
        url: "https://127.0.0.1:2/mcp",
        config_json: Jason.encode!(%{"headers" => %{}, "timeout_ms" => 1_000})
      })

    auth = authority_with_server(digest)

    {:error, %Prima.Refusal{stage: :admission, message: message}} =
      Sanctum.Gate.call_in_chain("othersrv:issues.list", guest(ctx), %{}, auth,
        lineage: Cyfr.Test.AttemptFixtures.lineage!(guest(ctx))
      )

    assert message =~ "Denied by chain authority"
  end

  test "editing the server's config moves the digest and the grant stops matching",
       %{ctx: ctx, digest: digest} do
    auth = authority_with_server(digest)

    {:ok, _} =
      Arca.McpServerStorage.update(Sanctum.Context.actor(ctx), "ghserver", %{
        url: "https://elsewhere.example/mcp"
      })

    # The digest cache is tenant-invalidated on config mutation.
    Emissary.External.Proxy.invalidate_external_tools_cache(ctx)

    {:error, %Prima.Refusal{stage: :admission, message: message}} =
      Sanctum.Gate.call_in_chain("ghserver:issues.list", guest(ctx), %{}, auth,
        lineage: Cyfr.Test.AttemptFixtures.lineage!(guest(ctx))
      )

    assert message =~ "Denied by chain authority"
  end

  test "a program's definition replaced with wider hosts no longer matches its grant",
       %{ctx: ctx} do
    actor = Sanctum.Context.actor(ctx)

    {:ok, program} =
      Arca.McpServerStorage.insert(actor, %{
        cap: 0,
        name: "fetcher",
        transport: "program",
        mark: "mcp",
        url: nil,
        hosts: Jason.encode!(["api.example.com"]),
        config_json:
          Jason.encode!(%{
            "backends" => [%{"name" => "fetch", "command" => "npx -y fetch", "env" => %{}}],
            "timeout_ms" => 1_000
          })
      })

    {:ok, digest} = Sanctum.ToolServerDigest.from_server(program)
    auth = authority_with_server(digest, "fetcher")

    # The grant matches the restricted definition: the call passes the
    # authority and fails only at the program, which nothing runs here.
    {:error, reason} =
      Sanctum.Gate.call_in_chain("fetcher:issues.list", guest(ctx), %{}, auth,
        lineage: Cyfr.Test.AttemptFixtures.lineage!(guest(ctx))
      )

    refute match?(%Prima.Refusal{stage: :admission}, reason)

    # The whole definition replaced, the same command, every public host.
    {:ok, _} =
      Arca.McpServerStorage.update(actor, "fetcher", %{hosts: nil}, program.epoch)

    Emissary.External.Proxy.invalidate_external_tools_cache(ctx)

    assert {:error,
            %Prima.Refusal{stage: :admission, class: :forbidden, reason: {:invoke_denied, _}}} =
             Sanctum.Gate.call_in_chain("fetcher:issues.list", guest(ctx), %{}, auth,
               lineage: Cyfr.Test.AttemptFixtures.lineage!(guest(ctx))
             )
  end

  # The call under `auth` passes the authority (it fails later, at the
  # upstream nothing serves here) or is refused by it.
  defp authorized?(ctx, auth) do
    case Sanctum.Gate.call_in_chain("ghserver:issues.list", guest(ctx), %{}, auth,
           lineage: Cyfr.Test.AttemptFixtures.lineage!(guest(ctx))
         ) do
      {:error, %Prima.Refusal{stage: :admission, class: :forbidden, reason: {:invoke_denied, _}}} ->
        false

      {:error, _upstream} ->
        true
    end
  end

  # The server's whole definition replaced through `mcp_servers.update`, the
  # edit's own path, at the epoch it stands at now.
  defp edit(ctx, config, extra \\ %{}) do
    {:ok, %{epoch: epoch}} = Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "ghserver")
    on_exit(fn -> Emissary.External.ServerSupervisor.stop("ghserver", ctx.athanor_id) end)

    assert {:ok, _} =
             Emissary.External.Provider.handle(
               "mcp_servers",
               ctx,
               Map.merge(
                 %{
                   "action" => "update",
                   "name" => "ghserver",
                   "epoch" => epoch,
                   "config" => config
                 },
                 extra
               )
             )

    Emissary.External.Proxy.invalidate_external_tools_cache(ctx)
  end

  @granted %{
    "url" => "https://127.0.0.1:1/mcp",
    "headers" => %{},
    "timeout_ms" => 1_000,
    "tool_patterns" => ["issues.*", "repo_get"]
  }

  test "an edit that changes neither the address nor a header keeps the grant",
       %{ctx: ctx, digest: digest} do
    auth = authority_with_server(digest)
    assert authorized?(ctx, auth)

    # The same definition saved again, another timeout and other tool
    # patterns: none changes where the calls go or what rides along.
    for config <- [
          @granted,
          %{@granted | "timeout_ms" => 5_000},
          %{@granted | "tool_patterns" => ["issues.*"]}
        ] do
      edit(ctx, config)
      assert authorized?(ctx, auth), inspect(config)
    end
  end

  test "an edit of the address or of any header no longer matches the grant, a literal Host among them",
       %{ctx: ctx} do
    for name <- ["gh-key", "gh-key-2"] do
      {:ok, _} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: name,
          kind: "api_key",
          fields: %{"token" => "ghp_grant_test_0123456789"},
          destination: %{"hosts" => ["127.0.0.1", "127.0.0.2"], "port" => 1}
        })
    end

    # The grant is made for a definition carrying a vault-bound header and
    # a literal one.
    granted = %{
      @granted
      | "headers" => %{"Authorization" => "Bearer vault:gh-key", "X-Team" => "blue"}
    }

    edit(ctx, granted)
    {:ok, server} = Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "ghserver")
    {:ok, digest} = Sanctum.ToolServerDigest.from_server(server)
    auth = authority_with_server(digest)
    assert authorized?(ctx, auth)

    for config <- [
          %{granted | "url" => "https://127.0.0.2:1/mcp"},
          %{granted | "url" => "https://127.0.0.1:1/other"},
          put_in(granted, ["headers", "Authorization"], "Bearer vault:gh-key-2"),
          %{granted | "headers" => %{"X-Team" => "blue"}},
          put_in(granted, ["headers", "X-Team"], "green"),
          %{granted | "headers" => %{"Authorization" => "Bearer vault:gh-key"}},
          # The address and the vault-bound header kept, a literal Host
          # added: a peer routing on it sends the credential elsewhere.
          put_in(granted, ["headers", "Host"], "other-tenant.example")
        ] do
      edit(ctx, config)
      refute authorized?(ctx, auth), inspect(config)

      edit(ctx, granted)
      assert authorized?(ctx, auth)
    end
  end

  test "an unknown server resolves to the sentinel and denies", %{ctx: ctx, digest: digest} do
    auth = authority_with_server(digest)

    {:error, %Prima.Refusal{stage: :admission, message: message}} =
      Sanctum.Gate.call_in_chain("ghost:issues.list", guest(ctx), %{}, auth,
        lineage: Cyfr.Test.AttemptFixtures.lineage!(guest(ctx))
      )

    assert message =~ "Denied by chain authority"
  end
end
