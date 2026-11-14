# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.External.ServerProgramTest do
  @moduledoc """
  The program arm of an external MCP server against a program that answers
  as an MCP server over stdio does (`Cyfr.Test.ScriptedBackends`): its
  `tools/list` pages under `nextCursor`, which the connect follows to the
  last page, and a call it cannot serve is answered with a JSON-RPC error,
  which the call answers as a failure.
  """
  use ExUnit.Case, async: false

  alias Cyfr.Test.ScriptedBackends, as: Scripted
  alias Emissary.External.Servers

  @root :crypto.strong_rand_bytes(32)
  @secret "ghp_program-test-secret-0123456789"
  @generation_key {Arca.ControlPlane, :generation}
  @tools ~w(github__search github__issues github__pulls)

  setup do
    Cyfr.Test.Sandbox.setup!()
    Arca.Cache.init()

    ctx = Sanctum.TestContext.local()
    fake = Scripted.start(self(), @root)

    on_exit(fn ->
      :persistent_term.erase(@generation_key)
      Arca.ControlPlane.record(:unclaimed)
    end)

    Scripted.supervise_controller(url: fake.url, root: @root, tick_ms: 3_600_000)
    assert_receive {:control, "hello", %{"g" => 1}, _fields}, 2_000
    assert_receive {:control, "reconcile", %{"keep" => []}, _fields}, 2_000

    {:ok, _entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "gh-token",
        kind: "api_key",
        fields: %{"token" => @secret},
        destination: %{"hosts" => ["api.example.com"]},
        disclose: true
      })

    {:ok, row} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: "gh",
        transport: "program",
        mark: "mcp",
        url: nil,
        config_json:
          Jason.encode!(%{
            "backends" => [
              %{
                "name" => "github",
                "command" => "npx -y @modelcontextprotocol/server-github",
                "env" => %{"GITHUB_TOKEN" => "vault:gh-token"}
              }
            ],
            "timeout_ms" => 5_000
          })
      })

    Scripted.set(fake, :tools, %{row.id => @tools})
    {:ok, ctx: ctx, fake: fake, row: row}
  end

  defp server_pid(ctx, row) do
    [{pid, _digest}] =
      Registry.lookup(Emissary.External.ServerRegistry, {row.name, ctx.athanor_id})

    pid
  end

  test "a listing paged one tool a page is followed to its last page", %{ctx: ctx, row: row} do
    assert {:ok, tools} = Servers.ensure_started(row, ctx)
    assert Enum.map(tools, & &1["name"]) == @tools

    for _page <- @tools, do: assert_receive({:invoke, "tools/list", _fields})
    refute_received {:invoke, "tools/list", _fields}
  end

  test "a call the program answers with a JSON-RPC error fails, saying so",
       %{ctx: ctx, fake: fake, row: row} do
    assert {:ok, _tools} = Servers.ensure_started(row, ctx)
    pid = server_pid(ctx, row)

    # The program no longer serves `pulls`, as one upgraded underneath.
    Scripted.set(fake, :tools, %{row.id => ["github__search"]})

    assert {:ok, %{"content" => [%{"text" => "found"}]}} =
             Emissary.External.Server.call_tool(pid, "github__search", %{})

    # The program's own message, not a result read as success.
    assert {:error, "Unknown tool: pulls"} =
             Emissary.External.Server.call_tool(pid, "github__pulls", %{})
  end
end
