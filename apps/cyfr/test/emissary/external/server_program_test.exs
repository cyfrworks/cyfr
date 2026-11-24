# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.External.ServerProgramTest do
  @moduledoc """
  The program arm of an external MCP server against a program that answers
  as an MCP server over stdio does (`Cyfr.Test.ScriptedBackends`): its
  `tools/list` pages under `nextCursor`, which the connect follows to the
  last page, a call it cannot serve is answered with a JSON-RPC error,
  which the call answers as a failure, and its tools are listed and
  named on an API key as `<row>:<tool>`.
  """
  use ExUnit.Case, async: false

  alias Cyfr.Test.ScriptedBackends, as: Scripted
  alias Emissary.External.Servers

  @root :crypto.strong_rand_bytes(32)
  @secret "ghp_program-test-secret-0123456789"
  @generation_key {Arca.ControlPlane, :generation}
  @tools ~w(search issues pulls)

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
            "command" => "npx -y @modelcontextprotocol/server-github",
            "env" => %{"GITHUB_TOKEN" => "vault:gh-token"},
            "timeout_ms" => 5_000,
            "console" => true
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

  # The server's process asked again for, as the server asks for it.
  defp ask_again(pid) do
    %{lifetime: lifetime} = :sys.get_state(pid)
    Opus.Programs.box_open(lifetime, pid, %{}, System.system_time(:millisecond) + 10_000)
  end

  defp close_process(pid) do
    %{lifetime: lifetime} = :sys.get_state(pid)
    Opus.Programs.box_close(lifetime)
  end

  test "a second ask for a running lifetime answers the same process, and one for a closed lifetime is refused",
       %{ctx: ctx, fake: fake, row: row} do
    assert {:ok, _tools} = Servers.ensure_started(row, ctx)
    pid = server_pid(ctx, row)
    assert [{session, %{running: true}}] = Map.to_list(Scripted.sessions(fake, row.id))

    assert {:ok, %{session: ^session, resumed: true}} = ask_again(pid)

    assert close_process(pid) == :ok
    assert {:error, {:refused, :lifetime_over, _boot}} = ask_again(pid)
    assert [{^session, %{running: false}}] = Map.to_list(Scripted.sessions(fake, row.id))

    # The next call starts the program afresh, as another lifetime.
    assert {:ok, %{"content" => [%{"text" => "found"}]}} =
             Emissary.External.Server.call_tool(pid, "search", %{})

    assert [_next] = for({id, %{running: true}} <- Scripted.sessions(fake, row.id), do: id)
  end

  test "a tool server opens through the box, which sends nothing without its slot",
       %{ctx: ctx, fake: fake, row: row} do
    assert {:ok, _tools} = Servers.ensure_started(row, ctx)
    pid = server_pid(ctx, row)
    assert_receive {:session, "open", _wire, _fields}, 2_000
    Scripted.end_sessions(fake, row.id)
    Arca.ControlPlane.record(:lost)

    assert {:error, _sentence} = Emissary.External.Server.call_tool(pid, "search", %{})
    refute_received {:session, "open", _wire, _fields}
    Arca.ControlPlane.record(:unclaimed)
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
    Scripted.set(fake, :tools, %{row.id => ["search"]})

    assert {:ok, %{"content" => [%{"text" => "found"}]}} =
             Emissary.External.Server.call_tool(pid, "search", %{})

    # The program's own message, not a result read as success.
    assert {:error, "Unknown tool: pulls"} =
             Emissary.External.Server.call_tool(pid, "pulls", %{})
  end

  # A program states what it offers in `initialize`'s answer: one with no
  # tools connects and is never asked for them, and its resources and
  # prompts are listed, read and got.
  test "a program that declares resources and prompts and no tools connects, and they are " <>
         "listed, read and got",
       %{ctx: ctx, fake: fake, row: row} do
    Scripted.set(fake, :offers, %{row.id => ["resources", "prompts"]})
    assert {:ok, []} = Servers.ensure_started(row, ctx)
    pid = server_pid(ctx, row)

    assert {:ok,
            %{
              "resources" => [%{"uri" => "file:///readme"}],
              "resourceTemplates" => [%{"uriTemplate" => "file:///{path}"}]
            }} = Emissary.External.Server.offering(pid, {:resources, :list})

    assert {:ok, %{"contents" => [%{"text" => "read file:///notes"}]}} =
             Emissary.External.Server.offering(pid, {:resources, :read, "file:///notes"})

    assert {:ok, %{"prompts" => [%{"name" => "greet"}]}} =
             Emissary.External.Server.offering(pid, {:prompts, :list})

    assert {:ok, %{"messages" => [%{"role" => "user", "content" => %{"text" => "greet me"}}]}} =
             Emissary.External.Server.offering(pid, {:prompts, :get, "greet", %{"who" => "me"}})

    assert_receive {:invoke, "initialize", _fields}
    refute_received {:invoke, "tools/list", _fields}
  end

  # A reinitialize opens the program's session again, which resumes while
  # its process runs and is then not initialized again: what the program
  # declared at its start still stands, and its tools are listed.
  test "a reinitialize whose program's session resumes keeps what the program declared",
       %{ctx: ctx, row: row} do
    assert {:ok, tools} = Servers.ensure_started(row, ctx)
    assert {:ok, :ready} = Emissary.External.Server.reinitialize(row.name, ctx.athanor_id)
    assert {:ok, ^tools} = Emissary.External.Server.get_tools(row.name, ctx.athanor_id)
    assert Enum.map(tools, & &1["name"]) == @tools
  end

  test "a program that declares neither is never asked for them", %{ctx: ctx, row: row} do
    assert {:ok, _tools} = Servers.ensure_started(row, ctx)
    pid = server_pid(ctx, row)

    for {asked, offering} <- [{{:resources, :list}, "resources"}, {{:prompts, :list}, "prompts"}] do
      assert {:error, {:invalid_argument, sentence}} =
               Emissary.External.Server.offering(pid, asked)

      assert sentence =~ "declares no #{offering}"
    end

    refute_received {:invoke, "resources/" <> _, _fields}
    refute_received {:invoke, "prompts/" <> _, _fields}
  end

  # A key narrowed to a program's tool names it as discovery lists it,
  # `<row>:<tool>`, compared as written (`Sanctum.ApiKey.admit_tool/2`).
  describe "a key narrowed to a program's tool" do
    @not_named "This API key may run only the tools named when it was made, and this is " <>
                 "not one of them."

    defp narrowed_key!(ctx, name, tools) do
      _owner = Sanctum.TestContext.owner!()
      issuer = Sanctum.TestContext.issuer!(%{ctx | user_id: Arca.Test.Actor.owner_id()})

      {:ok, %{api_key: raw}} =
        Sanctum.TestContext.create_key(issuer, %{name: name, scope: ["execute"], tools: tools})

      {:ok, key} = Sanctum.Caller.establish({:api_key, raw}, client_ip: "127.0.0.1")
      key
    end

    defp listed(ctx), do: ctx |> Sanctum.Visibility.external_tools() |> Enum.map(& &1["name"])

    defp call(ctx, name) do
      Emissary.MCP.Router.dispatch(ctx, %Prima.MCP.Message{
        type: :request,
        id: 7,
        method: "tools/call",
        params: %{"name" => name, "arguments" => %{}}
      })
    end

    setup %{ctx: ctx, row: row} do
      Emissary.External.Proxy.invalidate_external_tools_cache(ctx)

      on_exit(fn ->
        Emissary.External.ServerSupervisor.stop(row.name, ctx.athanor_id)
        Emissary.External.Proxy.invalidate_external_tools_cache(ctx)
      end)
    end

    test "is shown and runs that tool alone", %{ctx: ctx} do
      assert Enum.sort(listed(ctx)) == ["gh:issues", "gh:pulls", "gh:search"]
      key = narrowed_key!(ctx, "search-only", ["gh:search"])

      assert listed(key) == ["gh:search"]
      assert {:ok, %{"isError" => false}} = call(key, "gh:search")

      for name <- ["gh:issues", "gh:pulls"] do
        assert {name, call(key, name)} == {name, {:error, :insufficient_permissions, @not_named}}
      end
    end

    # The name a program's tool had while a program was a set of backends,
    # `<row>:<backend>__<tool>`, names no tool the program lists now: none
    # is shown, every listed one is refused, and the old name itself runs
    # nothing.
    test "named by its former backend-prefixed name, admits none of its tools", %{ctx: ctx} do
      key = narrowed_key!(ctx, "former-name", ["gh:github__search"])

      assert listed(key) == []

      for name <- ["gh:search", "gh:issues", "gh:pulls"] do
        assert {name, call(key, name)} == {name, {:error, :insufficient_permissions, @not_named}}
      end

      # The name the key holds is admitted as written, and the program
      # answers that it serves no such tool.
      assert call(key, "gh:github__search") ==
               {:ok,
                %{
                  "content" => [%{"type" => "text", "text" => "Unknown tool: github__search"}],
                  "isError" => true
                }}
    end
  end
end
