# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.BridgeTest do
  @moduledoc """
  The MCP bridge controller and the stdio arm of a server process, against
  a fake bridge that verifies every signature the way the bridge does:
  the controller greets the bridge and reconciles at start; a stdio server
  syncs its owner with its env sealed for its version and the bridge's
  lifetime and signs every request with its owner key; a sync's caller
  waits for its backends while every other owner's lease is renewed, and a
  catalogue that changes later is listed again; every stop path releases
  the owner; renewal fences each owner against its row; a restarted bridge
  and a new generation are greeted and live owners synced again; nothing
  is sent without the control plane; refusals of a call are answered as
  their kind requires; a status names no more owners than the bridge
  answers for and is read no further than the control limit, each refusal
  of it its own typed result; an athanor, and the person who created the
  rows — the server's synthetic principal being one such person — each
  hold at most a quarter of the pool; no key reaches a status or a crash
  report.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Cyfr.BridgeAuth
  alias Emissary.MCP.Bridge
  alias Emissary.MCP.ExternalServers
  alias Emissary.MCP.McpServersTool

  @root :crypto.strong_rand_bytes(32)
  @secret "ghp_bridge-test-secret-0123456789"
  @generation_key {Cyfr.ControlPlane, :generation}
  @project_root Path.expand("../../../../..", __DIR__)

  defmodule FakeBridge do
    @moduledoc false
    # A bridge that checks what the real one checks before it acts — the
    # control MAC, the lifetime, the (generation, seq) high-water mark, and
    # an invoke's owner key and version — and reports every accepted
    # message to the test process. Each owner runs and lists the tools the
    # test sets for its server (running, rev 1 and `github__search` unless
    # set), and reports `stderr_bytes` of stderr tail per backend in a
    # status (none unless set): the fake does not bound its answers, so a
    # test can see what the controller makes of an unbounded one.

    import Plug.Conn

    alias Cyfr.BridgeAuth

    def start(test, root) do
      bypass = Bypass.open()

      # Supervised by the test before the controller is, so it answers until
      # the controller has stopped.
      agent =
        ExUnit.Callbacks.start_supervised!(
          {Agent,
           fn ->
             %{
               test: test,
               root: root,
               boot: "bb_first",
               hwm: {0, 0},
               owners: %{},
               readiness: %{},
               tools: %{},
               hold: MapSet.new(),
               pool: 32,
               stderr_bytes: 0,
               refuse: %{}
             }
           end},
          id: :fake_bridge
        )

      Bypass.stub(bypass, "POST", "/control", &serve(&1, fn conn -> control(conn, agent) end))
      Bypass.stub(bypass, "POST", "/mcp", &serve(&1, fn conn -> invoke(conn, agent) end))
      %{bypass: bypass, agent: agent, url: "http://127.0.0.1:#{bypass.port}"}
    end

    # Once the fake runs a request it traps exits, so a request whose client
    # goes away mid-way (a controller that crashes while the fake holds its
    # sync) still runs to its answer, 503 if the fake's state is gone. A
    # request cut off before that, or while its body is read, ends with its
    # connection and Bypass fails the test for it, so no test ends with a
    # message of the controller's in flight (`supervise_bridge/1`).
    defp serve(conn, handler) do
      Process.flag(:trap_exit, true)
      handler.(conn)
    catch
      :exit, _reason -> resp(conn, 503, "")
    end

    def restart(%{agent: agent}, boot),
      do: Agent.update(agent, &%{&1 | boot: boot, hwm: {0, 0}, owners: %{}})

    @doc "Refuse the next message of `what` (or invoke of that method) with `code` under `status`."
    def refuse_once(%{agent: agent}, what, code, status \\ 409),
      do: Agent.update(agent, &put_in(&1, [:refuse, what], {code, status}))

    def set(%{agent: agent}, key, value), do: Agent.update(agent, &Map.put(&1, key, value))
    def get(%{agent: agent}, key), do: Agent.get(agent, &Map.fetch!(&1, key))

    @doc "What the owner of `server` reports: its state and rev."
    def readiness(%{agent: agent}, server, state, rev),
      do: Agent.update(agent, &put_in(&1, [:readiness, server], %{state: state, rev: rev}))

    @doc "The tool names the owner of `server` lists."
    def tools(%{agent: agent}, server, names),
      do: Agent.update(agent, &put_in(&1, [:tools, server], names))

    @doc "Hold the next message of `type` until the test sends `:go` to the pid it reports."
    def hold(%{agent: agent}, type),
      do: Agent.update(agent, &%{&1 | hold: MapSet.put(&1.hold, type)})

    defp control(conn, agent) do
      {:ok, body, conn} = read_body(conn)
      st = Agent.get(agent, & &1)
      [header] = get_req_header(conn, "cyfr-bridge-auth")
      {:ok, fields, mac} = BridgeAuth.parse_header(:control, header)
      message = Jason.decode!(body)

      cond do
        not BridgeAuth.verify(:control, BridgeAuth.control_key(st.root), fields, mac, body) ->
          answer(conn, st, 401, %{"error" => "unauthorized"})

        fields.boot != if(message["type"] == "hello", do: "-", else: st.boot) ->
          answer(conn, st, 409, %{"error" => "stale_boot"})

        {fields.generation, fields.seq} <= st.hwm ->
          answer(conn, st, 409, %{"error" => "stale_control"})

        true ->
          Agent.update(agent, &%{&1 | hwm: {fields.generation, fields.seq}})
          send(st.test, {:control, message["type"], message, fields})
          held(agent, message["type"])

          case pop_refusal(agent, message["type"]) do
            nil -> handle(conn, agent, message, fields)
            {code, status} -> answer(conn, st, status, %{"error" => code})
          end
      end
    end

    defp held(agent, type) do
      st = Agent.get(agent, & &1)

      if MapSet.member?(st.hold, type) do
        Agent.update(agent, &%{&1 | hold: MapSet.delete(&1.hold, type)})
        send(st.test, {:held, type, self()})

        receive do
          :go -> :ok
        after
          5_000 -> :ok
        end
      end
    end

    defp readiness_of(st, server), do: Map.get(st.readiness, server, %{state: "running", rev: 1})

    defp handle(conn, agent, %{"type" => "hello"}, _fields) do
      st = Agent.get(agent, & &1)

      answer(conn, st, 200, %{
        "boot" => st.boot,
        "pool" => %{"size" => st.pool, "free" => st.pool}
      })
    end

    defp handle(conn, agent, %{"type" => "reconcile", "keep" => keep}, fields) do
      kept =
        for %{"athanor" => a, "server" => s, "e" => e} <- keep,
            do: {{a, s}, {fields.generation, e}}

      Agent.update(agent, fn st ->
        %{st | owners: Map.filter(st.owners, fn owner -> owner in kept end)}
      end)

      answer(conn, Agent.get(agent, & &1), 200, %{"released" => []})
    end

    defp handle(conn, agent, %{"type" => "sync"} = message, fields) do
      st = Agent.get(agent, & &1)
      %{"owner" => %{"athanor" => athanor, "server" => server}, "e" => e} = message

      owner = %{athanor: athanor, server: server, generation: fields.generation, epoch: e}

      {:ok, plaintext} =
        BridgeAuth.open(BridgeAuth.seal_key(st.root), owner, st.boot, message["sealed"])

      send(st.test, {:sealed_env, server, Jason.decode!(plaintext)})

      Agent.update(agent, &put_in(&1, [:owners, {athanor, server}], {fields.generation, e}))
      %{state: state, rev: rev} = readiness_of(st, server)

      backends =
        for backend <- message["backends"],
            do: %{"name" => backend["name"], "status" => "ready", "tools" => 1}

      answer(conn, st, 200, %{"status" => state, "rev" => rev, "backends" => backends})
    end

    defp handle(conn, agent, %{"type" => "renew", "owners" => owners}, fields) do
      st = Agent.get(agent, & &1)

      {renewed, unknown} =
        Enum.split_with(owners, fn %{"athanor" => a, "server" => s, "e" => e} ->
          Map.get(st.owners, {a, s}) == {fields.generation, e}
        end)

      renewed =
        for %{"server" => server} = owner <- renewed do
          %{state: state, rev: rev} = readiness_of(st, server)
          Map.merge(owner, %{"state" => state, "rev" => rev})
        end

      answer(conn, st, 200, %{"renewed" => renewed, "unknown" => unknown})
    end

    defp handle(conn, agent, %{"type" => "release", "owners" => owners}, fields) do
      released =
        for %{"athanor" => a, "server" => s, "e" => e} = owner <- owners,
            version = Agent.get(agent, &Map.get(&1.owners, {a, s})),
            version != nil and version <= {fields.generation, e},
            do: owner

      Agent.update(agent, fn st ->
        %{st | owners: Map.drop(st.owners, Enum.map(released, &{&1["athanor"], &1["server"]}))}
      end)

      answer(conn, Agent.get(agent, & &1), 200, %{"released" => released})
    end

    defp handle(conn, agent, %{"type" => "status", "owners" => named}, _fields) do
      st = Agent.get(agent, & &1)

      owners =
        for owner <- named,
            {g, e} <- List.wrap(Map.get(st.owners, {owner["athanor"], owner["server"]})) do
          Map.merge(owner, %{
            "g" => g,
            "e" => e,
            "backends" => [
              %{
                "name" => "github",
                "status" => "ready",
                "restarts" => 0,
                "stderr_tail" => String.duplicate("x", st.stderr_bytes)
              }
            ]
          })
        end

      answer(conn, st, 200, %{"owners" => owners})
    end

    defp invoke(conn, agent) do
      {:ok, body, conn} = read_body(conn)
      st = Agent.get(agent, & &1)
      [header] = get_req_header(conn, "cyfr-bridge-auth")
      {:ok, fields, mac} = BridgeAuth.parse_header(:invoke, header)

      {:ok, key} =
        BridgeAuth.owner_key(st.root, Map.take(fields, [:athanor, :server, :generation, :epoch]))

      message = Jason.decode!(body)
      running = Map.get(st.owners, {fields.athanor, fields.server})
      version = {fields.generation, fields.epoch}

      cond do
        not BridgeAuth.verify(:invoke, key, fields, mac, body) ->
          answer(conn, st, 401, %{})

        fields.boot != st.boot ->
          answer(conn, st, 409, %{"error" => "stale_boot"})

        running == nil ->
          answer(conn, st, 409, %{"error" => "unknown_owner"})

        version < running ->
          answer(conn, st, 409, %{"error" => "stale_epoch"})

        version > running ->
          answer(conn, st, 409, %{"error" => "epoch_ahead"})

        refusal = pop_refusal(agent, message["method"]) ->
          {code, status} = refusal
          send(st.test, {:invoke, message["method"], fields})
          answer(conn, st, status, %{"error" => code})

        true ->
          send(st.test, {:invoke, message["method"], fields})

          answer(conn, st, 200, %{
            "jsonrpc" => "2.0",
            "id" => message["id"],
            "result" => result(st, fields.server, message)
          })
      end
    end

    defp result(st, server, %{"method" => "tools/list"}) do
      names = Map.get(st.tools, server, ["github__search"])

      %{
        "tools" =>
          for(name <- names, do: %{"name" => name, "inputSchema" => %{"type" => "object"}})
      }
    end

    defp result(_st, _server, %{"method" => "tools/call"}),
      do: %{"content" => [%{"type" => "text", "text" => "found"}]}

    defp pop_refusal(agent, what) do
      Agent.get_and_update(agent, fn st ->
        {Map.get(st.refuse, what), %{st | refuse: Map.delete(st.refuse, what)}}
      end)
    end

    defp answer(conn, st, status, body) do
      conn
      |> put_resp_header("cyfr-bridge-boot", st.boot)
      |> put_resp_content_type("application/json")
      |> resp(status, Jason.encode!(body))
    end
  end

  defmodule Teardown do
    @moduledoc false
    # Runs `stop` as the test's supervisor stops it: before every child
    # started ahead of it, while they all still run.
    use GenServer

    def start_link(stop), do: GenServer.start_link(__MODULE__, stop)

    @impl true
    def init(stop) do
      Process.flag(:trap_exit, true)
      {:ok, stop}
    end

    @impl true
    def terminate(_reason, stop), do: stop.()
  end

  # The sandbox owner is not the test process: the controller, which reads
  # the store, still has it while it is stopped after the test.
  setup do
    Cyfr.Test.Sandbox.setup!()
    Arca.Cache.init()

    ctx = Sanctum.TestContext.local()
    fake = FakeBridge.start(self(), @root)

    on_exit(fn ->
      :persistent_term.erase(@generation_key)
      Cyfr.ControlPlane.mark(:unclaimed)
    end)

    {:ok, ctx: ctx, fake: fake}
  end

  defp start_bridge(fake, opts \\ []) do
    bridge =
      supervise_bridge(Keyword.merge([url: fake.url, root: @root, tick_ms: 3_600_000], opts))

    assert_receive {:control, "hello", %{"g" => 1}, %{boot: "-"}}, 2_000
    assert_receive {:control, "reconcile", %{"keep" => []}, _fields}, 2_000
    await_idle(bridge)
    bridge
  end

  # The controller, stopped when the test ends as the application stops it:
  # after the server processes, which release their owners through it as
  # they stop, and only once it has nothing left to send. Stopped with a
  # message in flight, it would cut off the request the fake is serving.
  defp supervise_bridge(opts) do
    bridge = start_supervised!({Bridge, opts})
    start_supervised!({Teardown, &quiesce/0}, shutdown: 10_000)
    bridge
  end

  defp quiesce do
    for {_id, pid, _type, _modules} <-
          DynamicSupervisor.which_children(Emissary.MCP.ExternalServerSupervisor) do
      DynamicSupervisor.terminate_child(Emissary.MCP.ExternalServerSupervisor, pid)
    end

    eventually(
      fn ->
        state = :sys.get_state(Bridge)
        state.owners == %{} and state.releases == %{} and idle?(state)
      end,
      "the controller to run no owner and have nothing left to send"
    )
  end

  defp tick(bridge) do
    send(bridge, :tick)
    await_idle(bridge)
  end

  defp idle?(state),
    do: state.inflight == nil and :queue.is_empty(state.urgent) and :queue.is_empty(state.queue)

  # Until the controller has no message in flight and none queued.
  defp await_idle(bridge, deadline \\ System.monotonic_time(:millisecond) + 3_000) do
    state = :sys.get_state(bridge)

    cond do
      idle?(state) ->
        state

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the controller did not settle")

      true ->
        Process.sleep(10)
        await_idle(bridge, deadline)
    end
  end

  defp eventually(check, what, deadline \\ System.monotonic_time(:millisecond) + 3_000) do
    case check.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline,
          do: flunk("timed out waiting for #{what}")

        Process.sleep(10)
        eventually(check, what, deadline)

      value ->
        value
    end
  end

  defp await_grant(pid, match) do
    eventually(
      fn ->
        grant = :sys.get_state(pid).bridge
        grant != nil and match.(grant) and grant
      end,
      "the server process to hold a matching grant"
    )
  end

  defp stdio_row(ctx, name, env \\ %{"GITHUB_TOKEN" => "vault:gh-token"}) do
    {:ok, row} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        name: name,
        transport: "stdio",
        url: nil,
        config_json:
          Jason.encode!(%{
            "backends" => [
              %{
                "name" => "github",
                "command" => "npx -y @modelcontextprotocol/server-github",
                "env" => env
              }
            ],
            "timeout_ms" => 5_000
          })
      })

    row
  end

  defp vault_entry(ctx) do
    {:ok, entry} =
      Sanctum.Vault.create(ctx, %{
        name: "gh-token",
        kind: "api_key",
        fields: %{"token" => @secret}
      })

    entry
  end

  defp connect(ctx, row) do
    assert {:ok, [%{"name" => "github__search"}]} = ExternalServers.ensure_started(row, ctx)
    server_pid(ctx, row)
  end

  defp server_pid(ctx, row) do
    [{pid, _digest}] =
      Registry.lookup(Emissary.MCP.ExternalServerRegistry, {row.name, ctx.athanor_id})

    pid
  end

  defp assert_released(row, epoch) do
    assert_receive {:control, "release", %{"owners" => owners}, _fields}, 3_000
    assert %{"server" => row.id, "e" => epoch} in Enum.map(owners, &Map.delete(&1, "athanor"))
    await_idle(Process.whereis(Bridge))
  end

  # How a binary looks wherever a term holding it is inspected, from its
  # first bytes, so a truncated rendering is caught too.
  defp rendered(key),
    do: inspect(binary_part(key, 0, 8), binaries: :as_binaries) |> String.trim_trailing(">>")

  test "at start the controller greets the bridge under generation 1 and keeps nothing", %{
    fake: fake
  } do
    bridge = start_bridge(fake)
    assert %{boot: "bb_first", generation: 1, pool_size: 32} = :sys.get_state(bridge)
  end

  test "a stdio server syncs with its env sealed for its version and lifetime, and signs every request",
       %{ctx: ctx, fake: fake} do
    start_bridge(fake)
    vault_entry(ctx)
    row = stdio_row(ctx, "gh")
    pid = connect(ctx, row)

    assert_receive {:control, "sync", sync, %{generation: 1, boot: "bb_first"}}, 2_000

    assert %{
             "owner" => %{"athanor" => athanor, "server" => server},
             "e" => 1,
             "lease_ms" => 30_000,
             "idle_ms" => 900_000,
             "backends" => [%{"name" => "github", "env_names" => ["GITHUB_TOKEN"]}]
           } = sync

    assert {athanor, server} == {ctx.athanor_id, row.id}
    refute Map.has_key?(hd(sync["backends"]), "env")
    assert_receive {:sealed_env, ^server, %{"github" => %{"GITHUB_TOKEN" => @secret}}}

    assert_receive {:invoke, "tools/list",
                    %{athanor: ^athanor, server: ^server, generation: 1, epoch: 1}}

    assert {:ok, %{"content" => [%{"text" => "found"}]}} =
             Emissary.MCP.ExternalServer.call_tool(pid, "github__search", %{"q" => "x"})

    assert_receive {:invoke, "tools/call", %{boot: "bb_first", nonce: first_nonce}}

    assert {:ok, _} = Emissary.MCP.ExternalServer.call_tool(pid, "github__search", %{})
    assert_receive {:invoke, "tools/call", %{nonce: second_nonce}}
    refute first_nonce == second_nonce

    # The process holds its owner key and no env value.
    refute inspect(:sys.get_state(pid), limit: :infinity) =~ @secret
    refute inspect(:sys.get_state(Process.whereis(Bridge)), limit: :infinity) =~ @secret
  end

  describe "readiness" do
    test "a sync waiting for its backends holds no other owner's renewal back, and answers once its wait passes",
         %{ctx: ctx, fake: fake} do
      start_bridge(fake, tick_ms: 100, ready_wait_ms: 1_200)
      kept = stdio_row(ctx, "kept", %{"NODE_ENV" => "production"})
      connect(ctx, kept)
      assert_receive {:control, "sync", %{"owner" => %{"server" => kept_id}}, _}, 2_000
      assert kept_id == kept.id

      slow = stdio_row(ctx, "slow", %{"NODE_ENV" => "production"})
      FakeBridge.readiness(fake, slow.id, "starting", 0)
      FakeBridge.tools(fake, slow.id, [])
      started = System.monotonic_time(:millisecond)
      waiting = Task.async(fn -> ExternalServers.ensure_started(slow, ctx) end)
      assert_receive {:control, "sync", %{"owner" => %{"server" => slow_id}}, _}, 2_000
      assert slow_id == slow.id

      for _ <- 1..4 do
        assert_receive {:control, "renew", %{"owners" => owners}, _}, 1_000
        assert kept.id in Enum.map(owners, & &1["server"])
      end

      refute Task.yield(waiting, 0)
      assert {:ok, []} = Task.await(waiting, 5_000)
      assert System.monotonic_time(:millisecond) - started >= 1_200
    end

    test "a sync's caller is answered as soon as the bridge reports its owner running",
         %{ctx: ctx, fake: fake} do
      start_bridge(fake, ready_wait_ms: 10_000)
      row = stdio_row(ctx, "soon", %{"NODE_ENV" => "production"})
      FakeBridge.readiness(fake, row.id, "starting", 0)
      waiting = Task.async(fn -> ExternalServers.ensure_started(row, ctx) end)
      assert_receive {:control, "sync", _sync, _fields}, 2_000
      assert_receive {:control, "renew", _renew, _fields}, 1_000

      FakeBridge.readiness(fake, row.id, "running", 1)
      assert {:ok, [%{"name" => "github__search"}]} = Task.await(waiting, 2_000)
    end

    test "a backend that becomes ready after the wait has its tools discovered without a refresh",
         %{ctx: ctx, fake: fake} do
      start_bridge(fake, ready_wait_ms: 300)
      row = stdio_row(ctx, "late", %{"NODE_ENV" => "production"})
      FakeBridge.readiness(fake, row.id, "starting", 0)
      FakeBridge.tools(fake, row.id, [])
      Phoenix.PubSub.subscribe(Emissary.PubSub, Cyfr.Bus.mcp_servers(ctx.athanor_id))

      assert {:ok, []} = ExternalServers.ensure_started(row, ctx)
      pid = server_pid(ctx, row)
      refute_received :mcp_servers_changed

      FakeBridge.tools(fake, row.id, ["github__search"])
      FakeBridge.readiness(fake, row.id, "running", 2)

      assert_receive :mcp_servers_changed, 3_000
      assert [%{"name" => "github__search"}] = :sys.get_state(pid).tools

      assert {:ok, [%{"name" => "github__search"}]} =
               Emissary.MCP.ExternalServer.get_tools("late", ctx.athanor_id)
    end
  end

  describe "every stop path releases the owner" do
    setup %{ctx: ctx, fake: fake} do
      bridge = start_bridge(fake)
      vault_entry(ctx)
      row = stdio_row(ctx, "stoppable")
      pid = connect(ctx, row)
      assert_receive {:control, "sync", _sync, _fields}, 2_000
      admin = %{ctx | permissions: MapSet.new([:*])}
      {:ok, bridge: bridge, row: row, pid: pid, admin: admin}
    end

    test "delete commits, then releases", %{ctx: ctx, row: row, admin: admin} do
      assert {:ok, %{deleted: "stoppable"}} =
               McpServersTool.handle("mcp_servers", admin, %{
                 "action" => "delete",
                 "name" => "stoppable"
               })

      assert_released(row, 1)

      assert {:error, :not_found} =
               Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "stoppable")
    end

    test "disable raises the epoch and releases", %{ctx: ctx, row: row, admin: admin} do
      assert {:ok, %{enabled: false, epoch: 2}} =
               McpServersTool.handle("mcp_servers", admin, %{
                 "action" => "disable",
                 "name" => "stoppable"
               })

      assert_released(row, 1)

      assert {:ok, %{epoch: 2}} =
               Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "stoppable")
    end

    test "restart releases and syncs again at the next epoch", %{row: row, admin: admin} do
      assert {:ok, %{action: "restarted", epoch: 2, status: "ready"}} =
               McpServersTool.handle("mcp_servers", admin, %{
                 "action" => "restart",
                 "name" => "stoppable"
               })

      assert_released(row, 1)
      assert_receive {:control, "sync", %{"e" => 2}, _fields}, 2_000
    end

    test "a process that exits", %{row: row, pid: pid} do
      Process.exit(pid, :kill)
      assert_released(row, 1)
    end

    test "a release the bridge did not acknowledge is dropped once the owner is synced again at its epoch",
         %{ctx: ctx, fake: fake, bridge: bridge, row: row, pid: pid} do
      FakeBridge.refuse_once(fake, "release", "conflict")
      Process.exit(pid, :kill)
      assert_released(row, 1)
      assert %{releases: pending} = :sys.get_state(bridge)
      assert pending == %{{ctx.athanor_id, row.id} => 1}

      connect(ctx, row)
      assert_receive {:control, "sync", %{"e" => 1}, _fields}, 2_000
      assert %{releases: releases} = await_idle(bridge)
      assert releases == %{}

      tick(bridge)
      refute_received {:control, "release", _release, _fields}
    end

    test "a vault change raises the epoch after releasing in memory", %{ctx: ctx, row: row} do
      Application.put_env(:cyfr, :external_server_reconciler_enabled, true)
      on_exit(fn -> Application.put_env(:cyfr, :external_server_reconciler_enabled, false) end)
      start_supervised!(Emissary.MCP.ExternalServerReconciler)

      {:ok, entry} = Arca.VaultStorage.get_by_name(Sanctum.Context.actor(ctx), "gh-token")
      {:ok, _} = Sanctum.Vault.revoke(ctx, entry.id)

      assert_released(row, 1)
      :sys.get_state(Emissary.MCP.ExternalServerReconciler)

      assert {:ok, %{epoch: 2}} =
               Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "stoppable")
    end

    test "an archived athanor", %{ctx: ctx, row: row} do
      Application.put_env(:cyfr, :external_server_reconciler_enabled, true)
      on_exit(fn -> Application.put_env(:cyfr, :external_server_reconciler_enabled, false) end)
      start_supervised!(Emissary.MCP.ExternalServerReconciler)

      Phoenix.PubSub.broadcast(
        Emissary.PubSub,
        Cyfr.Bus.athanor_archived_global(),
        {:athanor_archived_global, ctx.athanor_id}
      )

      assert_released(row, 1)
    end

    test "renewal releases an owner whose row moved on, and raises the epoch of one the bridge forgot",
         %{ctx: ctx, bridge: bridge, row: row, pid: pid, fake: fake} do
      watched = Process.monitor(pid)
      tick(bridge)

      assert_receive {:control, "renew", %{"owners" => [%{"e" => 1}], "lease_ms" => 30_000}, _},
                     2_000

      refute_received {:control, "release", _release, _fields}

      # The bridge no longer runs it: the epoch is raised and the process stopped.
      FakeBridge.set(fake, :owners, %{})
      tick(bridge)
      assert_receive {:control, "renew", _renew, _fields}, 2_000
      assert_receive {:DOWN, ^watched, :process, ^pid, _reason}, 2_000
      assert_released(row, 1)

      assert {:ok, %{epoch: 2}} =
               Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "stoppable")

      # A row whose epoch moved without a stop fails the fence at renewal.
      other = stdio_row(ctx, "fenced")
      other_pid = connect(ctx, other)
      assert_receive {:control, "sync", %{"owner" => %{"server" => server}}, _}, 2_000
      assert server == other.id
      other_watched = Process.monitor(other_pid)
      {:ok, _} = Arca.McpServerStorage.bump_epoch(Sanctum.Context.actor(ctx), other.id)
      tick(bridge)
      assert_receive {:DOWN, ^other_watched, :process, ^other_pid, _reason}, 2_000
      assert_released(other, 1)
    end
  end

  test "the configured lease and idle period are what a sync asks for, renewed every third of the lease",
       %{ctx: ctx, fake: fake} do
    Application.put_env(:cyfr, :mcp_bridge_lease_ms, 6_000)
    Application.put_env(:cyfr, :mcp_bridge_idle_ms, 120_000)

    on_exit(fn ->
      Application.delete_env(:cyfr, :mcp_bridge_lease_ms)
      Application.delete_env(:cyfr, :mcp_bridge_idle_ms)
    end)

    bridge = supervise_bridge(url: fake.url, root: @root)
    assert %{lease_ms: 6_000, idle_ms: 120_000, tick_ms: 2_000} = :sys.get_state(bridge)
    assert_receive {:control, "hello", _hello, _fields}, 2_000

    vault_entry(ctx)
    connect(ctx, stdio_row(ctx, "leased"))

    assert_receive {:control, "sync", %{"lease_ms" => 6_000, "idle_ms" => 120_000}, _fields},
                   2_000

    tick(bridge)
    assert_receive {:control, "renew", %{"lease_ms" => 6_000}, _fields}, 2_000
  end

  test "a restarted bridge is greeted, reconciled and every live owner synced under its new boot",
       %{ctx: ctx, fake: fake} do
    bridge = start_bridge(fake)
    vault_entry(ctx)
    row = stdio_row(ctx, "survivor")
    pid = connect(ctx, row)
    assert_receive {:control, "sync", _sync, %{boot: "bb_first"}}, 2_000

    FakeBridge.restart(fake, "bb_second")
    tick(bridge)

    assert_receive {:control, "hello", _hello, %{boot: "-"}}, 2_000
    assert_receive {:control, "reconcile", _reconcile, %{boot: "bb_second"}}, 2_000
    assert_receive {:control, "sync", %{"e" => 1}, %{boot: "bb_second"}}, 2_000
    assert_receive {:sealed_env, _server, _env}
    await_grant(pid, &(&1.boot == "bb_second"))
    assert {:ok, _} = Emissary.MCP.ExternalServer.call_tool(pid, "github__search", %{})
    assert_receive {:invoke, "tools/call", %{boot: "bb_second"}}
  end

  test "a new generation is greeted, and every live owner synced and granted under it",
       %{ctx: ctx, fake: fake} do
    bridge = start_bridge(fake)
    vault_entry(ctx)
    row = stdio_row(ctx, "regen")
    pid = connect(ctx, row)
    assert_receive {:control, "sync", _sync, %{generation: 1}}, 2_000

    :persistent_term.put(@generation_key, 2)
    tick(bridge)

    assert_receive {:control, "hello", %{"g" => 2}, %{generation: 2}}, 2_000
    assert_receive {:control, "reconcile", %{"keep" => []}, %{generation: 2}}, 2_000
    assert_receive {:control, "sync", _sync, %{generation: 2}}, 2_000
    await_grant(pid, &(&1.generation == 2))
    assert {:ok, _} = Emissary.MCP.ExternalServer.call_tool(pid, "github__search", %{})
    assert_receive {:invoke, "tools/call", %{generation: 2, epoch: 1}}
  end

  test "nothing is sent, and no owner synced, while this boot does not own the control plane",
       %{ctx: ctx, fake: fake} do
    bridge = start_bridge(fake)
    row = stdio_row(ctx, "headless", %{"NODE_ENV" => "production"})
    Cyfr.ControlPlane.mark(:lost)

    assert {:error, :control_plane_lost} =
             Bridge.sync(%{athanor_id: ctx.athanor_id, server_id: row.id, epoch: 1})

    tick(bridge)
    refute_receive {:control, _type, _message, _fields}, 200
  end

  test "while the generation cannot be read nothing is sent and no owner synced, and the next tick that reads it goes on",
       %{ctx: ctx, fake: fake} do
    reading = start_supervised!({Agent, fn -> :none end}, id: :generation_reading)
    bridge = start_bridge(fake, generation: fn -> Agent.get(reading, & &1) end)
    row = stdio_row(ctx, "unreadable", %{"NODE_ENV" => "production"})
    connect(ctx, row)
    assert_receive {:control, "sync", _sync, %{generation: 1}}, 2_000

    Agent.update(reading, fn _ -> {:error, :unavailable} end)
    tick(bridge)
    refute_receive {:control, _type, _message, _fields}, 200

    assert {:error, :control_plane_lost} =
             Bridge.sync(%{athanor_id: ctx.athanor_id, server_id: row.id, epoch: 1})

    assert Process.alive?(bridge)
    assert %{generation: 1, boot: "bb_first"} = :sys.get_state(bridge)

    Agent.update(reading, fn _ -> :none end)
    tick(bridge)

    assert_receive {:control, "renew", %{"owners" => [%{"server" => server}]}, %{generation: 1}},
                   2_000

    assert server == row.id
    refute_received {:control, "hello", _hello, _fields}
  end

  test "a call refused as epoch_ahead syncs again and is sent once more", %{ctx: ctx, fake: fake} do
    start_bridge(fake)
    row = stdio_row(ctx, "ahead", %{"NODE_ENV" => "production"})
    pid = connect(ctx, row)
    assert_receive {:control, "sync", _sync, _fields}, 2_000

    FakeBridge.refuse_once(fake, "tools/call", "epoch_ahead")

    assert {:ok, %{"content" => _}} =
             Emissary.MCP.ExternalServer.call_tool(pid, "github__search", %{})

    assert_receive {:invoke, "tools/call", _refused}
    assert_receive {:control, "sync", _again, _fields}, 2_000
    assert_receive {:invoke, "tools/call", _retried}
  end

  test "a call refused as stale_epoch after the row moved leaves the server in error",
       %{ctx: ctx, fake: fake} do
    start_bridge(fake)
    row = stdio_row(ctx, "moved", %{"NODE_ENV" => "production"})
    pid = connect(ctx, row)
    assert_receive {:control, "sync", _sync, _fields}, 2_000

    {:ok, _} = Arca.McpServerStorage.bump_epoch(Sanctum.Context.actor(ctx), row.id)
    FakeBridge.refuse_once(fake, "tools/call", "stale_epoch")

    assert {:error, message} = Emissary.MCP.ExternalServer.call_tool(pid, "github__search", %{})
    assert message =~ "changed"
    assert %{status: :error} = :sys.get_state(pid)
    refute_receive {:control, "sync", _sync, _fields}, 200
  end

  test "one athanor holds at most a quarter of the bridge's pool", %{ctx: ctx, fake: fake} do
    FakeBridge.set(fake, :pool, 4)
    start_bridge(fake)
    first = stdio_row(ctx, "first", %{"NODE_ENV" => "production"})
    second = stdio_row(ctx, "second", %{"NODE_ENV" => "production"})
    connect(ctx, first)
    assert_receive {:control, "sync", _sync, _fields}, 2_000

    assert {:error, {:pool_share, 1}} =
             Bridge.sync(%{athanor_id: ctx.athanor_id, server_id: second.id, epoch: 1})

    refute_receive {:control, "sync", _sync, _fields}, 200
  end

  test "the rows one person created hold at most a quarter of the pool across every athanor",
       %{ctx: ctx, fake: fake} do
    FakeBridge.set(fake, :pool, 8)
    start_bridge(fake)
    literal = %{"NODE_ENV" => "production"}

    for athanor <- ["ath_test", "ath_a"] do
      in_athanor = %{ctx | athanor_id: athanor}
      connect(in_athanor, stdio_row(in_athanor, "mine", literal))
      assert_receive {:control, "sync", _sync, _fields}, 2_000
    end

    in_third = %{ctx | athanor_id: "ath_b"}
    third = stdio_row(in_third, "mine", literal)

    assert {:error, {:person_share, 2}} =
             Bridge.sync(%{athanor_id: "ath_b", server_id: third.id, epoch: 1})

    refute_receive {:control, "sync", _sync, _fields}, 200

    # Another person's row in that athanor fits.
    someone = %{in_third | user_id: "usr_someone_else"}
    connect(someone, stdio_row(someone, "theirs", literal))
    assert_receive {:control, "sync", _sync, _fields}, 2_000
  end

  test "rows the server's synthetic principal created hold one person's share across every athanor",
       %{ctx: ctx, fake: fake} do
    FakeBridge.set(fake, :pool, 8)
    start_bridge(fake)
    literal = %{"NODE_ENV" => "production"}
    system = &Sanctum.Context.internal(athanor_id: &1, scope: :athanor)

    for athanor <- ["ath_test", "ath_a"] do
      as_system = system.(athanor)
      assert as_system.user_id == "system"
      row = stdio_row(as_system, "unattributed", literal)
      assert row.created_by == "system"
      connect(as_system, row)
      assert_receive {:control, "sync", _sync, _fields}, 2_000
    end

    third = stdio_row(system.("ath_b"), "unattributed", literal)

    assert {:error, {:person_share, 2}} =
             Bridge.sync(%{athanor_id: "ath_b", server_id: third.id, epoch: 1})

    refute_receive {:control, "sync", _sync, _fields}, 200

    # A person's row in that athanor fits: the synthetic principal's share is
    # its own, not the athanor's.
    person = %{ctx | athanor_id: "ath_b"}
    connect(person, stdio_row(person, "theirs", literal))
    assert_receive {:control, "sync", _sync, _fields}, 2_000
  end

  test "an env template that does not resolve refuses the sync and sends nothing", %{
    ctx: ctx,
    fake: fake
  } do
    start_bridge(fake)
    row = stdio_row(ctx, "unresolved", %{"GITHUB_TOKEN" => "vault:absent"})

    assert {:error, {:env_unresolved, "github", "GITHUB_TOKEN"}} =
             Bridge.sync(%{athanor_id: ctx.athanor_id, server_id: row.id, epoch: 1})

    refute_receive {:control, "sync", _sync, _fields}, 200
  end

  test "get reports what the bridge runs for a stdio server", %{ctx: ctx, fake: fake} do
    start_bridge(fake)
    row = stdio_row(ctx, "described", %{"NODE_ENV" => "production"})
    connect(ctx, row)
    admin = %{ctx | permissions: MapSet.new([:*])}

    assert {:ok,
            %{transport: "stdio", epoch: 1, status: "ready", backends: [%{"status" => "ready"}]}} =
             McpServersTool.handle("mcp_servers", admin, %{
               "action" => "get",
               "name" => "described"
             })

    assert_receive {:control, "status", %{"owners" => [%{"server" => server}]}, _fields}, 2_000
    assert server == row.id
  end

  describe "status" do
    test "is nil for an owner the bridge runs nothing for, its entry for one it runs, and names no more owners than the bridge's bound",
         %{ctx: ctx, fake: fake} do
      start_bridge(fake)
      assert {:ok, nil} = Bridge.status(ctx.athanor_id, "mcp_nothing")
      assert_receive {:control, "status", %{"owners" => [%{"server" => "mcp_nothing"}]}, _}, 2_000

      row = stdio_row(ctx, "running", %{"NODE_ENV" => "production"})
      connect(ctx, row)

      assert {:ok, %{"e" => 1, "backends" => [%{"status" => "ready"}]}} =
               Bridge.status(ctx.athanor_id, row.id)

      assert_receive {:control, "status", %{"owners" => owners}, _fields}, 2_000
      assert length(owners) <= Bridge.status_bounds().owners
    end

    test "each refusal of the bridge is its typed result, and a bridge that cannot be reached is unavailable",
         %{ctx: ctx, fake: fake} do
      start_bridge(fake)
      row = stdio_row(ctx, "bounded", %{"NODE_ENV" => "production"})
      connect(ctx, row)

      FakeBridge.refuse_once(fake, "status", "too_many_owners", 400)
      assert {:error, :too_many_owners} = Bridge.status(ctx.athanor_id, row.id)

      FakeBridge.refuse_once(fake, "status", "status_too_large")
      assert {:error, :status_too_large} = Bridge.status(ctx.athanor_id, row.id)

      Bypass.down(fake.bypass)
      assert {:error, :bridge_unavailable} = Bridge.status(ctx.athanor_id, row.id)

      Bypass.up(fake.bypass)
      assert {:ok, %{"e" => 1}} = Bridge.status(ctx.athanor_id, row.id)
    end

    test "an answer the bridge did not bound is stopped at the control limit and is status_too_large as well: neither read whole, emptied nor unavailable",
         %{ctx: ctx, fake: fake} do
      start_bridge(fake)
      row = stdio_row(ctx, "verbose", %{"NODE_ENV" => "production"})
      connect(ctx, row)
      FakeBridge.set(fake, :stderr_bytes, Bridge.status_bounds().bytes + 1)
      assert {:error, :status_too_large} = Bridge.status(ctx.athanor_id, row.id)

      FakeBridge.set(fake, :stderr_bytes, 0)
      assert {:ok, %{"e" => 1}} = Bridge.status(ctx.athanor_id, row.id)
    end

    test "the bounds the controller keeps are the bridge's literals" do
      source = File.read!(Path.join(@project_root, "apps/mcp-bridge/server.mjs"))
      %{owners: owners, bytes: bytes} = Bridge.status_bounds()

      assert [declared] =
               Regex.run(~r/export const MAX_STATUS_OWNERS = (\d+);/, source,
                 capture: :all_but_first
               )

      assert String.to_integer(declared) == owners

      assert [factor, times] =
               Regex.run(~r/export const CONTROL_BODY_LIMIT = (\d+) \* (\d+);/, source,
                 capture: :all_but_first
               )

      assert String.to_integer(factor) * String.to_integer(times) == bytes
      assert source =~ "export const STATUS_ANSWER_LIMIT = CONTROL_BODY_LIMIT;"
    end
  end

  describe "no key reaches a status or a crash report" do
    test "the controller's, with a sync in flight", %{ctx: ctx, fake: fake} do
      bridge = start_bridge(fake)
      vault_entry(ctx)
      row = stdio_row(ctx, "held")
      FakeBridge.hold(fake, "sync")
      Task.start(fn -> ExternalServers.ensure_started(row, ctx) end)
      assert_receive {:held, "sync", held}, 2_000

      keys = [@root, BridgeAuth.control_key(@root), BridgeAuth.seal_key(@root)]
      assert %{inflight: {_ref, {:sync, _key}, spec}} = :sys.get_state(bridge)
      for key <- keys, do: refute(inspect(spec, limit: :infinity) =~ rendered(key))

      {:status, _pid, _module, items} = :sys.get_status(bridge)

      assert %Bridge.State{root: "[REDACTED]", control_key: "[REDACTED]", seal_key: "[REDACTED]"} =
               status_state(items, Bridge.State)

      status = inspect(items, limit: :infinity, printable_limit: :infinity)
      for key <- keys, do: refute(status =~ rendered(key))

      # The report of a crash prints the state its reason carries, spec and all.
      log =
        capture_log(fn ->
          catch_exit(GenServer.call(bridge, :no_such_call))
          Process.sleep(200)
        end)

      released = Process.monitor(held)
      send(held, :go)
      assert_receive {:DOWN, ^released, :process, ^held, _reason}, 5_000
      assert log =~ "Emissary.MCP.Bridge.handle_call(:no_such_call"
      assert log =~ "inflight: {"
      for key <- keys, do: refute(log =~ rendered(key))
    end

    test "a server process's, with its grant and resolved headers", %{ctx: ctx, fake: fake} do
      start_bridge(fake)
      vault_entry(ctx)
      pid = connect(ctx, stdio_row(ctx, "granted"))
      owner_key = :sys.get_state(pid).bridge.owner_key

      {:status, _pid, _module, items} = :sys.get_status(pid)

      assert %Emissary.MCP.ExternalServer.State{bridge: %{owner_key: "[REDACTED]"}} =
               status_state(items, Emissary.MCP.ExternalServer.State)

      refute inspect(items, limit: :infinity, printable_limit: :infinity) =~ rendered(owner_key)

      log =
        capture_log(fn ->
          catch_exit(GenServer.call(pid, :no_such_call))
          Process.sleep(200)
        end)

      assert log =~ "Emissary.MCP.ExternalServer"
      refute log =~ rendered(owner_key)
      refute log =~ @secret
    end

    test "a message carrying a grant, and a reason carrying a state, are redacted" do
      grant = %{url: "http://bridge/mcp", owner_key: :crypto.strong_rand_bytes(32), epoch: 1}
      spec = %{control_key: :crypto.strong_rand_bytes(32), seal_key: <<1>>, sealed: "x", seq: 7}

      headers = %{"authorization" => "Bearer #{@secret}"}

      reason =
        {:function_clause, [{Bridge, :handle_call, [:bogus, spec, [headers: headers]], []}]}

      assert %{
               message: {:bridge_owner, %{owner_key: "[REDACTED]", url: "http://bridge/mcp"}},
               reason:
                 {:function_clause,
                  [
                    {Bridge, :handle_call,
                     [
                       :bogus,
                       %{
                         control_key: "[REDACTED]",
                         seal_key: "[REDACTED]",
                         sealed: "[REDACTED]",
                         seq: 7
                       },
                       [headers: %{"authorization" => "[REDACTED]"}]
                     ], []}
                  ]},
               log: [[:io | "data"]]
             } =
               Emissary.MCP.StatusRedaction.format_status(%{
                 message: {:bridge_owner, grant},
                 reason: reason,
                 log: [[:io | "data"]]
               })
    end
  end

  # The state term `:sys.get_status/1` reports for a GenServer.
  defp status_state(items, module) do
    items
    |> List.last()
    |> Keyword.get_values(:data)
    |> List.flatten()
    |> Enum.find_value(fn
      {~c"State", %^module{} = state} -> state
      _ -> nil
    end)
  end
end
