# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.BridgeTest do
  @moduledoc """
  The MCP bridge controller and the stdio arm of a server process, against
  a fake bridge that verifies every signature the way the bridge does:
  the controller greets the bridge and reconciles at start; a stdio server
  syncs its owner with its env sealed for its version and the bridge's
  lifetime and signs every request with its owner key; every stop path
  releases the owner; renewal fences each owner against its row; a
  restarted bridge and a new generation are greeted and live owners synced
  again; nothing is sent without the control plane; refusals of a call are
  answered as their kind requires; an athanor holds at most a quarter of
  the pool.
  """
  use ExUnit.Case, async: false

  alias Cyfr.BridgeAuth
  alias Emissary.MCP.Bridge
  alias Emissary.MCP.ExternalServers
  alias Emissary.MCP.McpServersTool

  @root :crypto.strong_rand_bytes(32)
  @secret "ghp_bridge-test-secret-0123456789"
  @generation_key {Cyfr.ControlPlane, :generation}

  defmodule FakeBridge do
    @moduledoc false
    # A bridge that checks what the real one checks before it acts — the
    # control MAC, the lifetime, the (generation, seq) high-water mark, and
    # an invoke's owner key and version — and reports every accepted
    # message to the test process.

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
               pool: 32,
               refuse: %{}
             }
           end},
          id: :fake_bridge
        )

      Bypass.stub(bypass, "POST", "/control", &control(&1, agent))
      Bypass.stub(bypass, "POST", "/mcp", &invoke(&1, agent))
      %{bypass: bypass, agent: agent, url: "http://127.0.0.1:#{bypass.port}"}
    end

    def restart(%{agent: agent}, boot),
      do: Agent.update(agent, &%{&1 | boot: boot, hwm: {0, 0}, owners: %{}})

    def refuse_once(%{agent: agent}, what, code),
      do: Agent.update(agent, &put_in(&1, [:refuse, what], code))

    def set(%{agent: agent}, key, value), do: Agent.update(agent, &Map.put(&1, key, value))
    def get(%{agent: agent}, key), do: Agent.get(agent, &Map.fetch!(&1, key))

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

          case pop_refusal(agent, message["type"]) do
            nil -> handle(conn, agent, message, fields)
            code -> answer(conn, st, 409, %{"error" => code})
          end
      end
    end

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

      backends =
        for backend <- message["backends"],
            do: %{"name" => backend["name"], "status" => "ready", "tools" => 1}

      answer(conn, st, 200, %{"status" => "running", "backends" => backends})
    end

    defp handle(conn, agent, %{"type" => "renew", "owners" => owners}, fields) do
      st = Agent.get(agent, & &1)

      {renewed, unknown} =
        Enum.split_with(owners, fn %{"athanor" => a, "server" => s, "e" => e} ->
          Map.get(st.owners, {a, s}) == {fields.generation, e}
        end)

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

    defp handle(conn, agent, %{"type" => "status", "owners" => [owner]}, _fields) do
      st = Agent.get(agent, & &1)

      owners =
        case Map.get(st.owners, {owner["athanor"], owner["server"]}) do
          nil ->
            []

          {g, e} ->
            [
              Map.merge(owner, %{
                "g" => g,
                "e" => e,
                "backends" => [%{"name" => "github", "status" => "ready", "restarts" => 0}]
              })
            ]
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

        code = pop_refusal(agent, message["method"]) ->
          send(st.test, {:invoke, message["method"], fields})
          answer(conn, st, 409, %{"error" => code})

        true ->
          send(st.test, {:invoke, message["method"], fields})

          answer(conn, st, 200, %{
            "jsonrpc" => "2.0",
            "id" => message["id"],
            "result" => result(message)
          })
      end
    end

    defp result(%{"method" => "tools/list"}),
      do: %{"tools" => [%{"name" => "github__search", "inputSchema" => %{"type" => "object"}}]}

    defp result(%{"method" => "tools/call"}),
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

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Arca.Cache.init()

    ctx = Sanctum.TestContext.local()
    fake = FakeBridge.start(self(), @root)

    on_exit(fn ->
      :persistent_term.erase(@generation_key)
      Cyfr.ControlPlane.mark(:unclaimed)

      for {_name, pid, _type, _modules} <-
            DynamicSupervisor.which_children(Emissary.MCP.ExternalServerSupervisor) do
        DynamicSupervisor.terminate_child(Emissary.MCP.ExternalServerSupervisor, pid)
      end
    end)

    {:ok, ctx: ctx, fake: fake}
  end

  defp start_bridge(fake) do
    start_supervised!({Bridge, url: fake.url, root: @root, tick_ms: 3_600_000})
    assert_receive {:control, "hello", %{"g" => 1}, %{boot: "-"}}, 2_000
    assert_receive {:control, "reconcile", %{"keep" => []}, _fields}, 2_000
    Process.whereis(Bridge)
  end

  defp tick(bridge) do
    send(bridge, :tick)
    await_idle(bridge)
  end

  # Until the controller has no message in flight and none queued.
  defp await_idle(bridge, deadline \\ System.monotonic_time(:millisecond) + 3_000) do
    state = :sys.get_state(bridge)

    cond do
      state.inflight == nil and :queue.is_empty(state.queue) ->
        state

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the controller did not settle")

      true ->
        Process.sleep(10)
        await_idle(bridge, deadline)
    end
  end

  defp await_grant(pid, match, deadline \\ System.monotonic_time(:millisecond) + 3_000) do
    grant = :sys.get_state(pid).bridge

    cond do
      grant != nil and match.(grant) ->
        grant

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the server process holds no matching grant")

      true ->
        Process.sleep(10)
        await_grant(pid, match, deadline)
    end
  end

  defp stdio_row(ctx, name, env \\ %{"GITHUB_TOKEN" => "vault:gh-token"}) do
    {:ok, row} =
      Arca.McpServerStorage.insert(ctx, %{
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

    [{pid, _digest}] =
      Registry.lookup(Emissary.MCP.ExternalServerRegistry, {row.name, ctx.athanor_id})

    pid
  end

  defp assert_released(row, epoch) do
    assert_receive {:control, "release", %{"owners" => owners}, _fields}, 3_000
    assert %{"server" => row.id, "e" => epoch} in Enum.map(owners, &Map.delete(&1, "athanor"))
    await_idle(Process.whereis(Bridge))
  end

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

    # The process holds its owner key and no env value; neither reaches a report.
    refute inspect(:sys.get_state(pid), limit: :infinity) =~ @secret
    {:status, _, _, items} = :sys.get_status(pid)
    refute inspect(items, limit: :infinity) =~ Base.encode16(:sys.get_state(pid).bridge.owner_key)
    refute inspect(:sys.get_state(Process.whereis(Bridge)), limit: :infinity) =~ @secret
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
      assert {:error, :not_found} = Arca.McpServerStorage.get(ctx, "stoppable")
    end

    test "disable raises the epoch and releases", %{ctx: ctx, row: row, admin: admin} do
      assert {:ok, %{enabled: false, epoch: 2}} =
               McpServersTool.handle("mcp_servers", admin, %{
                 "action" => "disable",
                 "name" => "stoppable"
               })

      assert_released(row, 1)
      assert {:ok, %{epoch: 2}} = Arca.McpServerStorage.get(ctx, "stoppable")
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

    test "a vault change raises the epoch after releasing in memory", %{ctx: ctx, row: row} do
      Application.put_env(:cyfr, :external_server_reconciler_enabled, true)
      on_exit(fn -> Application.put_env(:cyfr, :external_server_reconciler_enabled, false) end)
      start_supervised!(Emissary.MCP.ExternalServerReconciler)

      {:ok, entry} = Arca.VaultStorage.get_by_name(ctx.athanor_id, "gh-token")
      {:ok, _} = Sanctum.Vault.revoke(ctx, entry.id)

      assert_released(row, 1)
      :sys.get_state(Emissary.MCP.ExternalServerReconciler)
      assert {:ok, %{epoch: 2}} = Arca.McpServerStorage.get(ctx, "stoppable")
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
      assert {:ok, %{epoch: 2}} = Arca.McpServerStorage.get(ctx, "stoppable")

      # A row whose epoch moved without a stop fails the fence at renewal.
      other = stdio_row(ctx, "fenced")
      other_pid = connect(ctx, other)
      assert_receive {:control, "sync", %{"owner" => %{"server" => server}}, _}, 2_000
      assert server == other.id
      other_watched = Process.monitor(other_pid)
      {:ok, _} = Arca.McpServerStorage.bump_epoch(ctx, other.id)
      tick(bridge)
      assert_receive {:DOWN, ^other_watched, :process, ^other_pid, _reason}, 2_000
      assert_released(other, 1)
    end
  end

  test "the configured lease is what a sync and a renewal ask for, renewed every third of it",
       %{ctx: ctx, fake: fake} do
    Application.put_env(:cyfr, :mcp_bridge_lease_ms, 6_000)
    on_exit(fn -> Application.delete_env(:cyfr, :mcp_bridge_lease_ms) end)

    bridge = start_supervised!({Bridge, url: fake.url, root: @root})
    assert %{lease_ms: 6_000, tick_ms: 2_000} = :sys.get_state(bridge)
    assert_receive {:control, "hello", _hello, _fields}, 2_000

    vault_entry(ctx)
    connect(ctx, stdio_row(ctx, "leased"))
    assert_receive {:control, "sync", %{"lease_ms" => 6_000}, _fields}, 2_000
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

    {:ok, _} = Arca.McpServerStorage.bump_epoch(ctx, row.id)
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
end
