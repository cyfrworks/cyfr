# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ToolServerGrantTest do
  # A server grant authorizes only its matching configuration digest.
  # Changing the server configuration invalidates the grant; an unreachable
  # but authorized server returns an upstream error, not an authorization denial.
  use ExUnit.Case, async: false

  alias Grimoire.Catalog
  alias Prima.Authority
  alias Prima.Authority.Blob

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Arca.Cache.init()

    ctx = Sanctum.TestContext.local()

    {:ok, server} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
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

  defp authority_with_server(digest) do
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
                  "server_name" => "ghserver",
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
      Catalog.call_in_chain("tools", guest(ctx), %{"action" => "list"}, auth,
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
      Catalog.call_in_chain("tools", guest(ctx), %{"action" => "list"}, auth,
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
    for tool_def <- Catalog.list_tools(),
        name = tool_def["name"],
        not String.contains?(name, ":"),
        action <- get_in(tool_def, ["inputSchema", "properties", "action", "enum"]) || [],
        :in_chain in Grimoire.Annotations.planes(tool_def, action),
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

    {:error, message} =
      Catalog.call_in_chain("ghserver:issues.list", guest(ctx), %{}, auth,
        lineage: Cyfr.Test.AttemptFixtures.lineage!(guest(ctx))
      )

    # It got PAST the authority — the failure is the unreachable upstream.
    refute message =~ "Denied by chain authority"
  end

  test "a tool outside the granted patterns is not callable", %{ctx: ctx, digest: digest} do
    auth = authority_with_server(digest)

    {:error, message} =
      Catalog.call_in_chain("ghserver:repo_get", guest(ctx), %{}, auth,
        lineage: Cyfr.Test.AttemptFixtures.lineage!(guest(ctx))
      )

    assert message =~ "Denied by chain authority"
  end

  test "one server's grant never authorizes another", %{ctx: ctx, digest: digest} do
    {:ok, _other} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: "othersrv",
        url: "https://127.0.0.1:2/mcp",
        config_json: Jason.encode!(%{"headers" => %{}, "timeout_ms" => 1_000})
      })

    auth = authority_with_server(digest)

    {:error, message} =
      Catalog.call_in_chain("othersrv:issues.list", guest(ctx), %{}, auth,
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

    {:error, message} =
      Catalog.call_in_chain("ghserver:issues.list", guest(ctx), %{}, auth,
        lineage: Cyfr.Test.AttemptFixtures.lineage!(guest(ctx))
      )

    assert message =~ "Denied by chain authority"
  end

  test "an unknown server resolves to the sentinel and denies", %{ctx: ctx, digest: digest} do
    auth = authority_with_server(digest)

    {:error, message} =
      Catalog.call_in_chain("ghost:issues.list", guest(ctx), %{}, auth,
        lineage: Cyfr.Test.AttemptFixtures.lineage!(guest(ctx))
      )

    assert message =~ "Denied by chain authority"
  end
end
