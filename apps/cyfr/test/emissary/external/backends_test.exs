# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.External.BackendsTest do
  @moduledoc """
  The backends controller and the stdio arm of a server process, against a
  scripted backends service (`Cyfr.Test.ScriptedBackends`) that speaks the
  wire (`Prima.LocusBackends`) and verifies every signature the way the
  service does: the controller greets the service and reconciles at start;
  a stdio server syncs its owner with its env sealed for its version and
  the service's lifetime and signs every request with its owner key; one member of the
  cell holds each backend's claim and the losers of a proposal start
  nothing, a member that loses a claim stands down without revoking what
  a peer now runs, and a claim that only lapsed is asked for again; a
  sync's caller waits for its backends while every other owner's lease is
  renewed, and a catalogue that changes later is listed again; every stop
  path releases the owner; renewal fences each owner against its row; a
  restarted service and a new generation are greeted and live owners synced
  again; nothing is sent and no claim written without the control plane;
  refusals of a call are answered as their kind requires; a status names
  no more owners than the service answers for and is read no further than
  the answer bound, each refusal of it, a refusal at another protocol
  version and an answer at one included, its own typed result; an athanor,
  and the person who created the rows — the server's synthetic principal
  being one such person — each hold at most a quarter of the pool; no key
  reaches a status or a crash report.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arca.JobClaims
  alias Cyfr.Test.ScriptedBackends, as: Scripted
  alias Emissary.External.Backends
  alias Emissary.External.Servers
  alias Emissary.External.Provider
  alias Prima.LocusBackends

  @root :crypto.strong_rand_bytes(32)
  @secret "ghp_backends-test-secret-0123456789"
  @generation_key {Arca.ControlPlane, :generation}
  @project_root Path.expand("../../../../..", __DIR__)
  # A member of the cell that is not this one. Every claim assertion below
  # reads the one row of a freshly inserted server id, so it measures this
  # test's own delta on a key nothing else in the suite writes.
  @peer "peer@cell#boot_0199a000-0000-7000-8000-00000000cell"

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
    fake = Scripted.start(self(), @root)

    on_exit(fn ->
      :persistent_term.erase(@generation_key)
      Arca.ControlPlane.record(:unclaimed)
    end)

    {:ok, ctx: ctx, fake: fake}
  end

  defp start_controller(fake, opts \\ []) do
    controller =
      supervise_controller(Keyword.merge([url: fake.url, root: @root, tick_ms: 3_600_000], opts))

    assert_receive {:control, "hello", %{"g" => 1}, %{boot: "-"}}, 2_000
    assert_receive {:control, "reconcile", %{"keep" => []}, _fields}, 2_000
    await_idle(controller)
    controller
  end

  # The controller, stopped when the test ends as the application stops it:
  # after the server processes, which release their owners through it as
  # they stop, and only once it has nothing left to send. Stopped with a
  # message in flight, it would cut off the request the fake is serving.
  defp supervise_controller(opts) do
    controller = start_supervised!({Backends, opts})
    start_supervised!({Teardown, &quiesce/0}, shutdown: 10_000)
    controller
  end

  defp quiesce do
    for {_id, pid, _type, _modules} <-
          DynamicSupervisor.which_children(Emissary.External.ServerSupervisor) do
      DynamicSupervisor.terminate_child(Emissary.External.ServerSupervisor, pid)
    end

    eventually(
      fn ->
        state = :sys.get_state(Backends)

        state.owners == %{} and state.releases == %{} and state.claims == %{} and
          state.releasing == %{} and idle?(state)
      end,
      "the controller to run no owner, hold no claim and have nothing left to send"
    )
  end

  defp tick(controller) do
    send(controller, :tick)
    await_idle(controller)
  end

  defp idle?(state),
    do: state.inflight == nil and :queue.is_empty(state.urgent) and :queue.is_empty(state.queue)

  # Until the controller has no message in flight and none queued.
  defp await_idle(controller, deadline \\ System.monotonic_time(:millisecond) + 3_000) do
    state = :sys.get_state(controller)

    cond do
      idle?(state) ->
        state

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the controller did not settle")

      true ->
        Process.sleep(10)
        await_idle(controller, deadline)
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
        grant = :sys.get_state(pid).grant
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
    assert {:ok, [%{"name" => "github__search"}]} = Servers.ensure_started(row, ctx)
    server_pid(ctx, row)
  end

  defp server_pid(ctx, row) do
    [{pid, _digest}] =
      Registry.lookup(Emissary.External.ServerRegistry, {row.name, ctx.athanor_id})

    pid
  end

  defp assert_released(row, epoch) do
    assert_receive {:control, "release", %{"owners" => owners}, _fields}, 3_000
    assert %{"server" => row.id, "e" => epoch} in Enum.map(owners, &Map.delete(&1, "athanor"))
    await_idle(Process.whereis(Backends))
  end

  # How a binary looks wherever a term holding it is inspected, from its
  # first bytes, so a truncated rendering is caught too.
  defp rendered(key),
    do: inspect(binary_part(key, 0, 8), binaries: :as_binaries) |> String.trim_trailing(">>")

  defp claim_key(ctx, row), do: ctx.athanor_id <> ":" <> row.id

  # The one `job_claims` row of this backend, as it reads now.
  defp claim_row(ctx, row) do
    assert {:ok, %{} = claim} = JobClaims.read("mcp_backend", claim_key(ctx, row))
    claim
  end

  defp claimed_by_peer(ctx, row) do
    assert {:ok, %{} = peer} =
             JobClaims.claim("mcp_backend", claim_key(ctx, row), @peer, 30_000)

    peer
  end

  test "at start the controller greets the service under generation 1 and keeps nothing", %{
    fake: fake
  } do
    controller = start_controller(fake)
    assert %{boot: "bb_first", generation: 1, pool_size: 32} = :sys.get_state(controller)
  end

  test "a stdio server syncs with its env sealed for its version and lifetime, and signs every request",
       %{ctx: ctx, fake: fake} do
    start_controller(fake)
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
             Emissary.External.Server.call_tool(pid, "github__search", %{"q" => "x"})

    assert_receive {:invoke, "tools/call", %{boot: "bb_first", nonce: first_nonce}}

    assert {:ok, _} = Emissary.External.Server.call_tool(pid, "github__search", %{})
    assert_receive {:invoke, "tools/call", %{nonce: second_nonce}}
    refute first_nonce == second_nonce

    # The process holds its owner key and no env value.
    refute inspect(:sys.get_state(pid), limit: :infinity) =~ @secret
    refute inspect(:sys.get_state(Process.whereis(Backends)), limit: :infinity) =~ @secret
  end

  describe "readiness" do
    test "a sync waiting for its backends holds no other owner's renewal back, and answers once its wait passes",
         %{ctx: ctx, fake: fake} do
      start_controller(fake, tick_ms: 100, ready_wait_ms: 1_200)
      kept = stdio_row(ctx, "kept", %{"NODE_ENV" => "production"})
      connect(ctx, kept)
      assert_receive {:control, "sync", %{"owner" => %{"server" => kept_id}}, _}, 2_000
      assert kept_id == kept.id

      slow = stdio_row(ctx, "slow", %{"NODE_ENV" => "production"})
      Scripted.readiness(fake, slow.id, "starting", 0)
      Scripted.tools(fake, slow.id, [])
      started = System.monotonic_time(:millisecond)
      waiting = Task.async(fn -> Servers.ensure_started(slow, ctx) end)
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

    test "a sync's caller is answered as soon as the service reports its owner running",
         %{ctx: ctx, fake: fake} do
      start_controller(fake, ready_wait_ms: 10_000)
      row = stdio_row(ctx, "soon", %{"NODE_ENV" => "production"})
      Scripted.readiness(fake, row.id, "starting", 0)
      waiting = Task.async(fn -> Servers.ensure_started(row, ctx) end)
      assert_receive {:control, "sync", _sync, _fields}, 2_000
      assert_receive {:control, "renew", _renew, _fields}, 1_000

      Scripted.readiness(fake, row.id, "running", 1)
      assert {:ok, [%{"name" => "github__search"}]} = Task.await(waiting, 2_000)
    end

    test "a backend that becomes ready after the wait has its tools discovered without a refresh",
         %{ctx: ctx, fake: fake} do
      start_controller(fake, ready_wait_ms: 300)
      row = stdio_row(ctx, "late", %{"NODE_ENV" => "production"})
      Scripted.readiness(fake, row.id, "starting", 0)
      Scripted.tools(fake, row.id, [])

      Cyfr.Bus.subscribe(
        Sanctum.Context.actor(ctx),
        Cyfr.Bus.mcp_servers(Sanctum.Context.actor(ctx))
      )

      assert {:ok, []} = Servers.ensure_started(row, ctx)
      pid = server_pid(ctx, row)
      refute_received %Cyfr.Bus.McpServers{}

      Scripted.tools(fake, row.id, ["github__search"])
      Scripted.readiness(fake, row.id, "running", 2)

      assert_receive %Cyfr.Bus.McpServers{kind: :changed}, 3_000
      assert [%{"name" => "github__search"}] = :sys.get_state(pid).tools

      assert {:ok, [%{"name" => "github__search"}]} =
               Emissary.External.Server.get_tools("late", ctx.athanor_id)
    end
  end

  describe "one claimed controller per backend" do
    test "the row admits one of two members proposing a backend, and the loser can tell which case it is",
         %{ctx: ctx, fake: fake} do
      start_controller(fake)
      vault_entry(ctx)
      row = stdio_row(ctx, "contended")
      peer = claimed_by_peer(ctx, row)

      assert {:error, :claimed_elsewhere} =
               Backends.sync(%{athanor_id: ctx.athanor_id, server_id: row.id, epoch: 1})

      # Nothing was sent, and nothing read: the row comes before the store
      # and before the vault, so a member that holds no claim resolves no
      # env template.
      refute_receive {:control, "sync", _sync, _fields}, 200
      refute_received {:sealed_env, _server, _env}
      assert %{owner: @peer, fence: fence} = claim_row(ctx, row)
      assert fence == peer.fence

      # The peer gives it up and this member takes it: one backend, one row.
      assert :ok = JobClaims.release(peer)

      assert {:ok, %{epoch: 1}} =
               Backends.sync(%{athanor_id: ctx.athanor_id, server_id: row.id, epoch: 1})

      assert_receive {:control, "sync", %{"e" => 1}, _fields}, 2_000
      assert %{owner: owner} = taken = claim_row(ctx, row)
      assert owner == Prima.Boot.id()
      assert JobClaims.live?(taken)

      # And giving the owner up here gives the row up with it, lease run
      # out, so the next member takes the backend at once.
      Backends.release(%{athanor_id: ctx.athanor_id, server_id: row.id, epoch: 1})
      given_up = claim_row(ctx, row)
      refute JobClaims.live?(given_up)
      assert given_up.fence > taken.fence
    end

    test "a backend's claim is leased for the service lease and renewed on the tick, so a successor waits out lease plus tick",
         %{ctx: ctx, fake: fake} do
      controller = supervise_controller(url: fake.url, root: @root)
      assert_receive {:control, "hello", _hello, _fields}, 2_000
      assert %{lease_ms: 30_000, tick_ms: 10_000} = :sys.get_state(controller)

      vault_entry(ctx)
      row = stdio_row(ctx, "leased-claim")
      connect(ctx, row)
      claim = claim_row(ctx, row)

      # Every write sets the two together, so the lease a successor waits
      # out is the service lease, and the tick that renews it a third of it.
      assert DateTime.diff(claim.lease_until, claim.updated_at, :millisecond) == 30_000

      # A crash report prints the state, claim rows and all: they survive
      # the redaction whole, holding nothing that has to be redacted.
      {:status, _pid, _module, items} = :sys.get_status(controller)
      assert %Backends.State{claims: held} = status_state(items, Backends.State)
      assert [%{owner: owner}] = Map.values(held)
      assert owner == Prima.Boot.id()
    end

    test "a member that loses its claim stops the backend here and revokes nothing a peer now runs",
         %{ctx: ctx, fake: fake} do
      controller = start_controller(fake, lease_ms: 300)
      vault_entry(ctx)
      row = stdio_row(ctx, "handed-over")
      pid = connect(ctx, row)
      assert_receive {:control, "sync", _sync, _fields}, 2_000
      watched = Process.monitor(pid)
      held = claim_row(ctx, row)

      # The lease runs out where this member cannot renew it, and a peer
      # takes the row over at a fence this member has never read.
      eventually(fn -> not JobClaims.live?(held) end, "the backend claim to run out")
      peer = claimed_by_peer(ctx, row)

      tick(controller)

      assert_receive {:DOWN, ^watched, :process, ^pid, _reason}, 2_000
      refute_received {:control, "release", _release, _fields}
      state = await_idle(controller)
      assert state.owners == %{}
      assert state.claims == %{}
      assert state.releases == %{}

      # The peer's row is untouched by the member that stood down, and what
      # that member still holds writes nothing: the fence refuses it.
      assert %{owner: @peer, fence: fence} = claim_row(ctx, row)
      assert fence == peer.fence
      assert :taken = JobClaims.release(held)
      refute_receive {:control, "release", _release, _fields}, 200
    end

    test "a claim that only lapsed is asked for again, and the backend runs on",
         %{ctx: ctx, fake: fake} do
      controller = start_controller(fake, lease_ms: 300)
      vault_entry(ctx)
      row = stdio_row(ctx, "lapsing")
      pid = connect(ctx, row)
      assert_receive {:control, "sync", _sync, _fields}, 2_000
      held = claim_row(ctx, row)

      eventually(fn -> not JobClaims.live?(held) end, "the backend claim to run out")
      tick(controller)

      assert %{owner: owner, fence: fence} = retaken = claim_row(ctx, row)
      assert owner == Prima.Boot.id()
      assert fence > held.fence
      assert JobClaims.live?(retaken)
      assert Process.alive?(pid)
      refute_received {:control, "release", _release, _fields}
      assert_receive {:control, "renew", %{"owners" => [%{"e" => 1}]}, _fields}, 2_000
    end

    test "an epoch bump gives the backend up here, and the new configuration takes it again",
         %{ctx: ctx, fake: fake} do
      controller = start_controller(fake)
      vault_entry(ctx)
      row = stdio_row(ctx, "reconfigured")
      pid = connect(ctx, row)
      assert_receive {:control, "sync", %{"e" => 1}, _fields}, 2_000
      first = claim_row(ctx, row)
      assert first.owner == Prima.Boot.id()

      watched = Process.monitor(pid)
      {:ok, _} = Arca.McpServerStorage.bump_epoch(Sanctum.Context.actor(ctx), row.id)
      tick(controller)

      assert_receive {:DOWN, ^watched, :process, ^pid, _reason}, 2_000
      assert_released(row, 1)

      given_up = claim_row(ctx, row)
      assert given_up.owner == Prima.Boot.id()
      assert given_up.fence > first.fence
      refute JobClaims.live?(given_up)

      assert {:ok, %{epoch: 2} = moved} =
               Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "reconfigured")

      connect(ctx, moved)
      assert_receive {:control, "sync", %{"e" => 2}, _fields}, 2_000
      taken = claim_row(ctx, row)
      assert taken.owner == Prima.Boot.id()
      assert taken.fence > given_up.fence
      assert JobClaims.live?(taken)
    end

    test "a member that does not hold the control plane renews no claim and sends nothing",
         %{ctx: ctx, fake: fake} do
      controller = start_controller(fake)
      vault_entry(ctx)
      row = stdio_row(ctx, "headless-claim")
      connect(ctx, row)
      assert_receive {:control, "sync", _sync, _fields}, 2_000
      before = claim_row(ctx, row)

      Arca.ControlPlane.record(:lost)
      tick(controller)

      refute_receive {:control, _type, _message, _fields}, 200
      assert claim_row(ctx, row).fence == before.fence

      # And the tick that finds the slot again renews both.
      Arca.ControlPlane.record(:unclaimed)
      tick(controller)
      assert_receive {:control, "renew", _renew, _fields}, 2_000
      assert claim_row(ctx, row).fence > before.fence
    end

    test "a controller whose generation cannot be read renews no claim and admits no sync",
         %{ctx: ctx, fake: fake} do
      reading = start_supervised!({Agent, fn -> :none end}, id: :claim_generation)
      controller = start_controller(fake, generation: fn -> Agent.get(reading, & &1) end)
      vault_entry(ctx)
      row = stdio_row(ctx, "ungenerated")
      connect(ctx, row)
      assert_receive {:control, "sync", _sync, %{generation: 1}}, 2_000
      before = claim_row(ctx, row)

      Agent.update(reading, fn _ -> {:error, :unavailable} end)
      tick(controller)

      refute_receive {:control, _type, _message, _fields}, 200
      assert claim_row(ctx, row).fence == before.fence

      other = stdio_row(ctx, "ungenerated-too", %{"NODE_ENV" => "production"})

      assert {:error, :control_plane_lost} =
               Backends.sync(%{athanor_id: ctx.athanor_id, server_id: other.id, epoch: 1})

      assert {:error, :not_found} = JobClaims.read("mcp_backend", claim_key(ctx, other))
      assert claim_row(ctx, row).fence == before.fence

      # And the tick that reads a generation again renews the claim.
      Agent.update(reading, fn _ -> :none end)
      tick(controller)
      assert_receive {:control, "renew", _renew, %{generation: 1}}, 2_000
      assert claim_row(ctx, row).fence > before.fence
    end

    test "a generation of this member's own keeps the backend's claim, and sends nothing under the old one",
         %{ctx: ctx, fake: fake} do
      controller = start_controller(fake)
      vault_entry(ctx)
      row = stdio_row(ctx, "regenerated")
      pid = connect(ctx, row)
      assert_receive {:control, "sync", _sync, %{generation: 1}}, 2_000
      before = claim_row(ctx, row)

      :persistent_term.put(@generation_key, 2)
      tick(controller)

      assert_receive {:control, "hello", %{"g" => 2}, %{generation: 2}}, 2_000
      refute_received {:control, "renew", _renew, %{generation: 1}}
      assert_receive {:control, "sync", %{"e" => 1}, %{generation: 2}}, 2_000
      await_grant(pid, &(&1.generation == 2))

      # The claim is the member's and not the generation's: the same member
      # goes on holding the backend across its own generation change.
      after_change = claim_row(ctx, row)
      assert after_change.owner == before.owner
      assert JobClaims.live?(after_change)
    end
  end

  describe "every stop path releases the owner" do
    setup %{ctx: ctx, fake: fake} do
      controller = start_controller(fake)
      vault_entry(ctx)
      row = stdio_row(ctx, "stoppable")
      pid = connect(ctx, row)
      assert_receive {:control, "sync", _sync, _fields}, 2_000
      admin = %{ctx | permissions: MapSet.new([:*])}
      {:ok, controller: controller, row: row, pid: pid, admin: admin}
    end

    test "delete commits, then releases", %{ctx: ctx, row: row, admin: admin} do
      assert {:ok, %{deleted: "stoppable"}} =
               Provider.handle("mcp_servers", admin, %{
                 "action" => "delete",
                 "name" => "stoppable"
               })

      assert_released(row, 1)

      assert {:error, :not_found} =
               Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "stoppable")
    end

    test "disable raises the epoch and releases", %{ctx: ctx, row: row, admin: admin} do
      assert {:ok, %{enabled: false, epoch: 2}} =
               Provider.handle("mcp_servers", admin, %{
                 "action" => "disable",
                 "name" => "stoppable"
               })

      assert_released(row, 1)

      assert {:ok, %{epoch: 2}} =
               Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "stoppable")
    end

    test "restart releases and syncs again at the next epoch", %{row: row, admin: admin} do
      assert {:ok, %{action: "restarted", epoch: 2, status: "ready"}} =
               Provider.handle("mcp_servers", admin, %{
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

    test "a release the service did not acknowledge is dropped once the owner is synced again at its epoch",
         %{ctx: ctx, fake: fake, controller: controller, row: row, pid: pid} do
      Scripted.refuse_once(fake, "release", "conflict")
      Process.exit(pid, :kill)
      assert_released(row, 1)
      assert %{releases: pending} = :sys.get_state(controller)
      assert pending == %{{ctx.athanor_id, row.id} => 1}

      connect(ctx, row)
      assert_receive {:control, "sync", %{"e" => 1}, _fields}, 2_000
      assert %{releases: releases} = await_idle(controller)
      assert releases == %{}

      tick(controller)
      refute_received {:control, "release", _release, _fields}
    end

    test "a vault change raises the epoch after releasing in memory", %{ctx: ctx, row: row} do
      Application.put_env(:cyfr, :external_server_reconciler_enabled, true)
      on_exit(fn -> Application.put_env(:cyfr, :external_server_reconciler_enabled, false) end)
      start_supervised!(Emissary.External.Reconciler)

      {:ok, entry} = Arca.VaultStorage.get_by_name(Sanctum.Context.actor(ctx), "gh-token")
      {:ok, _} = Sanctum.Vault.revoke(ctx, entry.id)

      assert_released(row, 1)
      :sys.get_state(Emissary.External.Reconciler)

      assert {:ok, %{epoch: 2}} =
               Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "stoppable")
    end

    test "an archived athanor", %{ctx: ctx, row: row} do
      Application.put_env(:cyfr, :external_server_reconciler_enabled, true)
      on_exit(fn -> Application.put_env(:cyfr, :external_server_reconciler_enabled, false) end)
      start_supervised!(Emissary.External.Reconciler)

      Cyfr.Bus.broadcast_global(
        Cyfr.Bus.athanor_archived_global(),
        Cyfr.Bus.AthanorArchived.new(ctx.athanor_id)
      )

      assert_released(row, 1)
    end

    test "renewal releases an owner whose row moved on, and raises the epoch of one the service forgot",
         %{ctx: ctx, controller: controller, row: row, pid: pid, fake: fake} do
      watched = Process.monitor(pid)
      tick(controller)

      assert_receive {:control, "renew", %{"owners" => [%{"e" => 1}], "lease_ms" => 30_000}, _},
                     2_000

      refute_received {:control, "release", _release, _fields}

      # The service no longer runs it: the epoch is raised and the process stopped.
      Scripted.set(fake, :owners, %{})
      tick(controller)
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
      tick(controller)
      assert_receive {:DOWN, ^other_watched, :process, ^other_pid, _reason}, 2_000
      assert_released(other, 1)
    end
  end

  test "the configured lease and idle period are what a sync asks for, renewed every third of the lease",
       %{ctx: ctx, fake: fake} do
    Application.put_env(:cyfr, :locus_backends_lease_ms, 6_000)
    Application.put_env(:cyfr, :locus_backends_idle_ms, 120_000)

    on_exit(fn ->
      Application.delete_env(:cyfr, :locus_backends_lease_ms)
      Application.delete_env(:cyfr, :locus_backends_idle_ms)
    end)

    controller = supervise_controller(url: fake.url, root: @root)
    assert %{lease_ms: 6_000, idle_ms: 120_000, tick_ms: 2_000} = :sys.get_state(controller)
    assert_receive {:control, "hello", _hello, _fields}, 2_000

    vault_entry(ctx)
    connect(ctx, stdio_row(ctx, "leased"))

    assert_receive {:control, "sync", %{"lease_ms" => 6_000, "idle_ms" => 120_000}, _fields},
                   2_000

    tick(controller)
    assert_receive {:control, "renew", %{"lease_ms" => 6_000}, _fields}, 2_000
  end

  test "a restarted service is greeted, reconciled and every live owner synced under its new boot",
       %{ctx: ctx, fake: fake} do
    controller = start_controller(fake)
    vault_entry(ctx)
    row = stdio_row(ctx, "survivor")
    pid = connect(ctx, row)
    assert_receive {:control, "sync", _sync, %{boot: "bb_first"}}, 2_000

    Scripted.restart(fake, "bb_second")
    tick(controller)

    assert_receive {:control, "hello", _hello, %{boot: "-"}}, 2_000
    assert_receive {:control, "reconcile", _reconcile, %{boot: "bb_second"}}, 2_000
    assert_receive {:control, "sync", %{"e" => 1}, %{boot: "bb_second"}}, 2_000
    assert_receive {:sealed_env, _server, _env}
    await_grant(pid, &(&1.boot == "bb_second"))
    assert {:ok, _} = Emissary.External.Server.call_tool(pid, "github__search", %{})
    assert_receive {:invoke, "tools/call", %{boot: "bb_second"}}
  end

  test "a new generation is greeted, and every live owner synced and granted under it",
       %{ctx: ctx, fake: fake} do
    controller = start_controller(fake)
    vault_entry(ctx)
    row = stdio_row(ctx, "regen")
    pid = connect(ctx, row)
    assert_receive {:control, "sync", _sync, %{generation: 1}}, 2_000

    :persistent_term.put(@generation_key, 2)
    tick(controller)

    assert_receive {:control, "hello", %{"g" => 2}, %{generation: 2}}, 2_000
    assert_receive {:control, "reconcile", %{"keep" => []}, %{generation: 2}}, 2_000
    assert_receive {:control, "sync", _sync, %{generation: 2}}, 2_000
    await_grant(pid, &(&1.generation == 2))
    assert {:ok, _} = Emissary.External.Server.call_tool(pid, "github__search", %{})
    assert_receive {:invoke, "tools/call", %{generation: 2, epoch: 1}}
  end

  test "nothing is sent, and no owner synced, while this boot does not own the control plane",
       %{ctx: ctx, fake: fake} do
    controller = start_controller(fake)
    row = stdio_row(ctx, "headless", %{"NODE_ENV" => "production"})
    Arca.ControlPlane.record(:lost)

    assert {:error, :control_plane_lost} =
             Backends.sync(%{athanor_id: ctx.athanor_id, server_id: row.id, epoch: 1})

    tick(controller)
    refute_receive {:control, _type, _message, _fields}, 200
  end

  test "while the generation cannot be read nothing is sent and no owner synced, and the next tick that reads it goes on",
       %{ctx: ctx, fake: fake} do
    reading = start_supervised!({Agent, fn -> :none end}, id: :generation_reading)
    controller = start_controller(fake, generation: fn -> Agent.get(reading, & &1) end)
    row = stdio_row(ctx, "unreadable", %{"NODE_ENV" => "production"})
    connect(ctx, row)
    assert_receive {:control, "sync", _sync, %{generation: 1}}, 2_000

    Agent.update(reading, fn _ -> {:error, :unavailable} end)
    tick(controller)
    refute_receive {:control, _type, _message, _fields}, 200

    assert {:error, :control_plane_lost} =
             Backends.sync(%{athanor_id: ctx.athanor_id, server_id: row.id, epoch: 1})

    assert Process.alive?(controller)
    assert %{generation: 1, boot: "bb_first"} = :sys.get_state(controller)

    Agent.update(reading, fn _ -> :none end)
    tick(controller)

    assert_receive {:control, "renew", %{"owners" => [%{"server" => server}]}, %{generation: 1}},
                   2_000

    assert server == row.id
    refute_received {:control, "hello", _hello, _fields}
  end

  test "a call refused as epoch_ahead syncs again and is sent once more", %{ctx: ctx, fake: fake} do
    start_controller(fake)
    row = stdio_row(ctx, "ahead", %{"NODE_ENV" => "production"})
    pid = connect(ctx, row)
    assert_receive {:control, "sync", _sync, _fields}, 2_000

    Scripted.refuse_once(fake, "tools/call", "epoch_ahead")

    assert {:ok, %{"content" => _}} =
             Emissary.External.Server.call_tool(pid, "github__search", %{})

    assert_receive {:invoke, "tools/call", _refused}
    assert_receive {:control, "sync", _again, _fields}, 2_000
    assert_receive {:invoke, "tools/call", _retried}
  end

  test "a call refused as stale_epoch after the row moved leaves the server in error",
       %{ctx: ctx, fake: fake} do
    start_controller(fake)
    row = stdio_row(ctx, "moved", %{"NODE_ENV" => "production"})
    pid = connect(ctx, row)
    assert_receive {:control, "sync", _sync, _fields}, 2_000

    {:ok, _} = Arca.McpServerStorage.bump_epoch(Sanctum.Context.actor(ctx), row.id)
    Scripted.refuse_once(fake, "tools/call", "stale_epoch")

    assert {:error, message} = Emissary.External.Server.call_tool(pid, "github__search", %{})
    assert message =~ "changed"
    assert %{status: :error} = :sys.get_state(pid)
    refute_receive {:control, "sync", _sync, _fields}, 200
  end

  test "one athanor holds at most a quarter of the service's pool", %{ctx: ctx, fake: fake} do
    Scripted.set(fake, :pool, 4)
    start_controller(fake)
    first = stdio_row(ctx, "first", %{"NODE_ENV" => "production"})
    second = stdio_row(ctx, "second", %{"NODE_ENV" => "production"})
    connect(ctx, first)
    assert_receive {:control, "sync", _sync, _fields}, 2_000

    assert {:error, {:pool_share, 1}} =
             Backends.sync(%{athanor_id: ctx.athanor_id, server_id: second.id, epoch: 1})

    refute_receive {:control, "sync", _sync, _fields}, 200
  end

  test "the rows one person created hold at most a quarter of the pool across every athanor",
       %{ctx: ctx, fake: fake} do
    Scripted.set(fake, :pool, 8)
    start_controller(fake)
    literal = %{"NODE_ENV" => "production"}

    for athanor <- ["ath_test", "ath_a"] do
      in_athanor = %{ctx | athanor_id: athanor}
      connect(in_athanor, stdio_row(in_athanor, "mine", literal))
      assert_receive {:control, "sync", _sync, _fields}, 2_000
    end

    in_third = %{ctx | athanor_id: "ath_b"}
    third = stdio_row(in_third, "mine", literal)

    assert {:error, {:person_share, 2}} =
             Backends.sync(%{athanor_id: "ath_b", server_id: third.id, epoch: 1})

    refute_receive {:control, "sync", _sync, _fields}, 200

    # Another person's row in that athanor fits.
    someone = %{in_third | user_id: "usr_someone_else"}
    connect(someone, stdio_row(someone, "theirs", literal))
    assert_receive {:control, "sync", _sync, _fields}, 2_000
  end

  test "rows the server's synthetic principal created hold one person's share across every athanor",
       %{ctx: ctx, fake: fake} do
    Scripted.set(fake, :pool, 8)
    start_controller(fake)
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
             Backends.sync(%{athanor_id: "ath_b", server_id: third.id, epoch: 1})

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
    start_controller(fake)
    row = stdio_row(ctx, "unresolved", %{"GITHUB_TOKEN" => "vault:absent"})

    assert {:error, {:env_unresolved, "github", "GITHUB_TOKEN"}} =
             Backends.sync(%{athanor_id: ctx.athanor_id, server_id: row.id, epoch: 1})

    refute_receive {:control, "sync", _sync, _fields}, 200
  end

  test "get reports what the service runs for a stdio server", %{ctx: ctx, fake: fake} do
    start_controller(fake)
    row = stdio_row(ctx, "described", %{"NODE_ENV" => "production"})
    connect(ctx, row)
    admin = %{ctx | permissions: MapSet.new([:*])}

    assert {:ok,
            %{transport: "stdio", epoch: 1, status: "ready", backends: [%{"status" => "ready"}]}} =
             Provider.handle("mcp_servers", admin, %{
               "action" => "get",
               "name" => "described"
             })

    assert_receive {:control, "status", %{"owners" => [%{"server" => server}]}, _fields}, 2_000
    assert server == row.id
  end

  describe "status" do
    test "is nil for an owner the service runs nothing for, its entry for one it runs, and names no more owners than the service's bound",
         %{ctx: ctx, fake: fake} do
      start_controller(fake)
      assert {:ok, nil} = Backends.status(ctx.athanor_id, "mcp_nothing")
      assert_receive {:control, "status", %{"owners" => [%{"server" => "mcp_nothing"}]}, _}, 2_000

      row = stdio_row(ctx, "running", %{"NODE_ENV" => "production"})
      connect(ctx, row)

      assert {:ok, %{"e" => 1, "backends" => [%{"status" => "ready"}]}} =
               Backends.status(ctx.athanor_id, row.id)

      assert_receive {:control, "status", %{"owners" => owners}, _fields}, 2_000
      assert length(owners) <= Backends.status_bounds().owners
    end

    test "each refusal of the service is its typed result, and a service that cannot be reached is unavailable",
         %{ctx: ctx, fake: fake} do
      start_controller(fake)
      row = stdio_row(ctx, "bounded", %{"NODE_ENV" => "production"})
      connect(ctx, row)

      Scripted.refuse_once(fake, "status", "too_many_owners", 400)
      assert {:error, :too_many_owners} = Backends.status(ctx.athanor_id, row.id)

      Scripted.refuse_once(fake, "status", "status_too_large")
      assert {:error, :status_too_large} = Backends.status(ctx.athanor_id, row.id)

      Bypass.down(fake.bypass)
      assert {:error, :backends_unavailable} = Backends.status(ctx.athanor_id, row.id)

      Bypass.up(fake.bypass)
      assert {:ok, %{"e" => 1}} = Backends.status(ctx.athanor_id, row.id)
    end

    test "an answer the service did not bound is stopped at the answer bound and is status_too_large as well: neither read whole, emptied nor unavailable",
         %{ctx: ctx, fake: fake} do
      start_controller(fake)
      row = stdio_row(ctx, "verbose", %{"NODE_ENV" => "production"})
      connect(ctx, row)
      Scripted.set(fake, :stderr_bytes, Backends.status_bounds().bytes + 1)
      assert {:error, :status_too_large} = Backends.status(ctx.athanor_id, row.id)

      Scripted.set(fake, :stderr_bytes, 0)
      assert {:ok, %{"e" => 1}} = Backends.status(ctx.athanor_id, row.id)
    end

    test "a refused signature, and a refusal or an answer at another protocol version, are their own typed results",
         %{ctx: ctx, fake: fake} do
      start_controller(fake)
      row = stdio_row(ctx, "versioned", %{"NODE_ENV" => "production"})
      connect(ctx, row)

      Scripted.refuse_once(fake, "status", "unauthorized")
      assert {:error, :backends_refused_signature} = Backends.status(ctx.athanor_id, row.id)

      Scripted.refuse_once(fake, "status", "version")
      assert {:error, :protocol_mismatch} = Backends.status(ctx.athanor_id, row.id)

      Scripted.set(fake, :answer_version, LocusBackends.version() + 1)
      assert {:error, :protocol_mismatch} = Backends.status(ctx.athanor_id, row.id)

      # A code that is not the one its status carries reads as nothing.
      Scripted.set(fake, :answer_version, LocusBackends.version())
      Scripted.refuse_once(fake, "status", "too_many_owners", 409)
      assert {:error, {:backends_status, 409}} = Backends.status(ctx.athanor_id, row.id)

      assert {:ok, %{"e" => 1}} = Backends.status(ctx.athanor_id, row.id)
    end

    test "the bounds the controller keeps are the wire's, as its vector file states them" do
      vectors =
        Path.join(@project_root, "tests/fixtures/locus_backends.json")
        |> File.read!()
        |> Jason.decode!()

      assert Backends.status_bounds() == %{
               owners: vectors["bounds"]["max_status_owners"],
               bytes: vectors["bounds"]["max_status_answer_bytes"]
             }
    end
  end

  describe "no key reaches a status or a crash report" do
    test "the controller's, with a sync in flight", %{ctx: ctx, fake: fake} do
      controller = start_controller(fake)
      vault_entry(ctx)
      row = stdio_row(ctx, "held")
      Scripted.hold(fake, "sync")
      Task.start(fn -> Servers.ensure_started(row, ctx) end)
      assert_receive {:held, "sync", held}, 2_000

      keys = [@root, LocusBackends.control_key(@root), LocusBackends.seal_key(@root)]
      assert %{inflight: {_ref, {:sync, _key}, spec}} = :sys.get_state(controller)
      for key <- keys, do: refute(inspect(spec, limit: :infinity) =~ rendered(key))

      {:status, _pid, _module, items} = :sys.get_status(controller)

      assert %Backends.State{
               root: "[REDACTED]",
               control_key: "[REDACTED]",
               seal_key: "[REDACTED]"
             } =
               status_state(items, Backends.State)

      status = inspect(items, limit: :infinity, printable_limit: :infinity)
      for key <- keys, do: refute(status =~ rendered(key))

      # The report of a crash prints the state its reason carries, spec and all.
      log =
        capture_log(fn ->
          catch_exit(GenServer.call(controller, :no_such_call))
          Process.sleep(200)
        end)

      released = Process.monitor(held)
      send(held, :go)
      assert_receive {:DOWN, ^released, :process, ^held, _reason}, 5_000
      assert log =~ "Emissary.External.Backends.handle_call(:no_such_call"
      assert log =~ "inflight: {"
      for key <- keys, do: refute(log =~ rendered(key))
    end

    test "a server process's, with its grant and resolved headers", %{ctx: ctx, fake: fake} do
      start_controller(fake)
      vault_entry(ctx)
      pid = connect(ctx, stdio_row(ctx, "granted"))
      owner_key = :sys.get_state(pid).grant.owner_key

      {:status, _pid, _module, items} = :sys.get_status(pid)

      assert %Emissary.External.Server.State{grant: %{owner_key: "[REDACTED]"}} =
               status_state(items, Emissary.External.Server.State)

      refute inspect(items, limit: :infinity, printable_limit: :infinity) =~ rendered(owner_key)

      log =
        capture_log(fn ->
          catch_exit(GenServer.call(pid, :no_such_call))
          Process.sleep(200)
        end)

      assert log =~ "Emissary.External.Server"
      refute log =~ rendered(owner_key)
      refute log =~ @secret
    end

    test "a message carrying a grant, and a reason carrying a state, are redacted" do
      grant = %{
        url: "http://locus-backends:4101/locus/v1/backends/mcp",
        owner_key: :crypto.strong_rand_bytes(32),
        epoch: 1
      }

      spec = %{control_key: :crypto.strong_rand_bytes(32), seal_key: <<1>>, sealed: "x", seq: 7}

      headers = %{"authorization" => "Bearer #{@secret}"}

      reason =
        {:function_clause, [{Backends, :handle_call, [:bogus, spec, [headers: headers]], []}]}

      assert %{
               message:
                 {:backends_owner,
                  %{
                    owner_key: "[REDACTED]",
                    url: "http://locus-backends:4101/locus/v1/backends/mcp"
                  }},
               reason:
                 {:function_clause,
                  [
                    {Backends, :handle_call,
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
               Emissary.External.StatusRedaction.format_status(%{
                 message: {:backends_owner, grant},
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
