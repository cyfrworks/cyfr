# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ProgramsTest do
  @moduledoc """
  The programs controller (`Opus.Programs`, its local box) and the stdio
  arm of a server process, against a scripted backends service
  (`Cyfr.Test.ScriptedBackends`) that speaks the wire (`Prima.LocusBackends`)
  and verifies every signature the way the service does: the box greets the
  service and reconciles at start; a stdio server holds its owner, synced
  with its programs and its env sealed for its version and the service's
  lifetime, and speaks MCP over a session per backend signed with its owner
  key; a session is read only while a call is outstanding, so one left
  alone is ended by idle and the next call opens and initializes it again,
  and one that ends fails the call awaiting it; one member of the cell
  holds each owner's claim, a member that loses it tells its holders to
  stand down without revoking what a peer now runs, and a claim that only
  lapsed is asked for again; every stop path releases the owner; renewal
  fences each owner against its row; a restarted service and a new
  generation are greeted and live owners synced again; nothing is sent
  without the control plane; refusals are answered as their kind requires;
  a status names no more owners than the service answers for and is read
  no further than the answer bound; a pipe row syncs with its program
  settings; a kept stdio row runs in its login entry's home; a sign-in is
  relayed both ways and ends with its command; a kept home is reset, and a
  retire is sent again until it lands; no key reaches a status or a crash
  report.
  """
  use ExUnit.Case, async: false

  # Where the cases' entries may go: an external server's credential is
  # resolved by name, and its destination is not what these cases test.
  @destination %{"hosts" => ["api.example.com"]}

  import ExUnit.CaptureLog

  alias Arca.JobClaims
  alias Cyfr.Test.ScriptedBackends, as: Scripted
  alias Opus.Programs
  alias Emissary.External.Servers
  alias Emissary.External.Provider
  alias Prima.LocusBackends

  @root :crypto.strong_rand_bytes(32)
  @secret "ghp_backends-test-secret-0123456789"
  @generation_key {Arca.ControlPlane, :generation}
  # A member of the cell that is not this one. Every claim assertion below
  # reads the one row of a freshly inserted server id, so it measures this
  # test's own delta on a key nothing else in the suite writes.
  @peer "peer@cell#boot_0199a000-0000-7000-8000-00000000cell"

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

  defp supervise_controller(opts), do: Scripted.supervise_controller(opts)

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
        cap: 0,
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

  # A backend's environment hands the value to the process it starts, so
  # the entry it reads is disclosed.
  defp vault_entry(ctx, over \\ %{}) do
    {:ok, entry} =
      Sanctum.TestContext.create_vault(
        ctx,
        Map.merge(
          %{
            name: "gh-token",
            kind: "api_key",
            fields: %{"token" => @secret},
            destination: @destination,
            disclose: true
          },
          over
        )
      )

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
    await_idle(GenServer.whereis(Programs.via("local")))
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
             "programs" => [
               %{"name" => "github", "env_names" => ["GITHUB_TOKEN"], "home" => "scratch"}
             ]
           } = sync

    assert {athanor, server} == {ctx.athanor_id, row.id}
    refute Map.has_key?(hd(sync["programs"]), "env")
    refute Map.has_key?(hd(sync["programs"]), "memory_bytes")
    assert_receive {:sealed_env, ^server, %{"github" => %{"GITHUB_TOKEN" => @secret}}}

    assert_receive {:session, "open", %{"program" => "github", "key" => "mcp", "mode" => "run"},
                    %{athanor: ^athanor, server: ^server, generation: 1, epoch: 1}}

    assert_receive {:invoke, "initialize", _fields}

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

    refute inspect(:sys.get_state(GenServer.whereis(Programs.via("local"))), limit: :infinity) =~
             @secret
  end

  describe "one claimed controller per backend" do
    test "the row admits one of two members proposing a backend, and the loser can tell which case it is",
         %{ctx: ctx, fake: fake} do
      start_controller(fake)
      vault_entry(ctx)
      row = stdio_row(ctx, "contended")
      peer = claimed_by_peer(ctx, row)

      assert {:error, :claimed_elsewhere} =
               Programs.hold(%{athanor_id: ctx.athanor_id, server_id: row.id, epoch: 1})

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
               Programs.hold(%{athanor_id: ctx.athanor_id, server_id: row.id, epoch: 1})

      assert_receive {:control, "sync", %{"e" => 1}, _fields}, 2_000
      assert %{owner: owner} = taken = claim_row(ctx, row)
      assert owner == Prima.Boot.id()
      assert JobClaims.live?(taken)

      # And giving the owner up here gives the row up with it, lease run
      # out, so the next member takes the backend at once.
      Programs.release(%{athanor_id: ctx.athanor_id, server_id: row.id, epoch: 1})
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
      assert %Opus.Programs.Box.State{claims: held} = status_state(items, Opus.Programs.Box.State)
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
               Programs.hold(%{athanor_id: ctx.athanor_id, server_id: other.id, epoch: 1})

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

      Prima.Test.Env.put_persistent_term(@generation_key, 2)
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
      Prima.Test.Env.put_app_env(:cyfr, :external_server_reconciler_enabled, true)
      start_supervised!(Emissary.External.Reconciler)

      {:ok, entry} = Arca.VaultStorage.get_by_name(Sanctum.Context.actor(ctx), "gh-token")
      {:ok, _} = Sanctum.Vault.revoke(ctx, entry.id)

      assert_released(row, 1)
      :sys.get_state(Emissary.External.Reconciler)

      assert {:ok, %{epoch: 2}} =
               Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), "stoppable")
    end

    test "an archived athanor", %{ctx: ctx, row: row} do
      Prima.Test.Env.put_app_env(:cyfr, :external_server_reconciler_enabled, true)
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
    Cyfr.Test.Settings.put("locus_backends_lease_ms", 6_000)
    Cyfr.Test.Settings.put("locus_backends_idle_ms", 120_000)

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

    Prima.Test.Env.put_persistent_term(@generation_key, 2)
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
             Programs.hold(%{athanor_id: ctx.athanor_id, server_id: row.id, epoch: 1})

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
             Programs.hold(%{athanor_id: ctx.athanor_id, server_id: row.id, epoch: 1})

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

    # The refused send carried the call and nothing ran; the owner is synced
    # again and the call sent once more, which runs.
    assert_receive {:control, "sync", _again, _fields}, 2_000
    assert_receive {:invoke, "tools/call", _retried}
    refute_receive {:invoke, "tools/call", _twice}, 200
  end

  test "a server that fails is not restarted, and its failures take no other server down",
       %{ctx: ctx, fake: fake} do
    start_controller(fake)
    failing = stdio_row(ctx, "failing", %{"NODE_ENV" => "production"})
    bystander_row = stdio_row(ctx, "bystander", %{"NODE_ENV" => "production"})
    bystander = connect(ctx, bystander_row)
    supervisor = Process.whereis(Emissary.External.ServerSupervisor)

    # More failures within the supervisor's restart window than its
    # intensity allows: each server is started again by its use alone.
    for _failure <- 1..5 do
      pid = connect(ctx, failing)
      down = Process.monitor(pid)
      capture_log(fn -> catch_exit(GenServer.call(pid, :no_such_call)) end)
      assert_receive {:DOWN, ^down, :process, ^pid, _crash}, 2_000

      assert Registry.lookup(Emissary.External.ServerRegistry, {failing.name, ctx.athanor_id}) ==
               []
    end

    assert Process.whereis(Emissary.External.ServerSupervisor) == supervisor
    assert Process.alive?(bystander)

    assert {:ok, %{"content" => _}} =
             Emissary.External.Server.call_tool(bystander, "github__search", %{})
  end

  test "a reader killed while its recv waits fails nothing of the service's", %{
    ctx: ctx,
    fake: fake
  } do
    # The server kills a session's reader whenever the session is dropped
    # (a refusal, a new grant), which may be while its recv still waits on
    # the service: a request whose client went away is no failure of the
    # service's, here or once the HTTP server has given up on it.
    start_controller(fake)
    row = stdio_row(ctx, "abandoned", %{"NODE_ENV" => "production"})
    pid = connect(ctx, row)
    %{grant: grant, sessions: sessions} = :sys.get_state(pid)
    [%{session: session}] = Map.values(sessions)

    reader = spawn(fn -> Opus.Programs.Session.recv(grant, session, 1_000_000, 25_000) end)
    assert_receive {:session, "recv", %{"after" => 1_000_000}, _fields}, 2_000
    Process.exit(reader, :kill)

    # Past the HTTP server's own wait for a request whose client is gone.
    Process.sleep(6_000)
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
             Programs.hold(%{athanor_id: ctx.athanor_id, server_id: second.id, epoch: 1})

    refute_receive {:control, "sync", _sync, _fields}, 200
  end

  test "an env template that does not resolve refuses the sync and sends nothing", %{
    ctx: ctx,
    fake: fake
  } do
    start_controller(fake)
    row = stdio_row(ctx, "unresolved", %{"GITHUB_TOKEN" => "vault:absent"})

    assert {:error, {:env_unresolved, "github", "GITHUB_TOKEN"}} =
             Programs.hold(%{athanor_id: ctx.athanor_id, server_id: row.id, epoch: 1})

    refute_receive {:control, "sync", _sync, _fields}, 200
  end

  test "stdio refuses an attach-only entry before starting a backend", %{ctx: ctx, fake: fake} do
    start_controller(fake)
    attached = vault_entry(ctx, %{disclose: false})
    admin = %{ctx | permissions: MapSet.new([:*])}
    actor = Sanctum.Context.actor(ctx)

    naming = fn entry ->
      %{
        "transport" => "stdio",
        "backends" => [
          %{
            "name" => "github",
            "command" => "npx -y @modelcontextprotocol/server-github",
            "env" => %{"GITHUB_TOKEN" => "vault:" <> entry, "NODE_ENV" => "production"}
          }
        ]
      }
    end

    refusal =
      "Backend 'github' env GITHUB_TOKEN names no active disclosed vault entry; " <>
        "a backend's environment takes only a disclosed entry"

    # Neither definition verb stores it, and neither names the entry.
    assert {:error, {:invalid_argument, ^refusal}} =
             Provider.handle("mcp_servers", admin, %{
               "action" => "create",
               "name" => "attached",
               "config" => naming.("gh-token")
             })

    assert {:error, :not_found} = Arca.McpServerStorage.get(actor, "attached")

    literal = stdio_row(ctx, "literal", %{"NODE_ENV" => "production"})

    assert {:error, {:invalid_argument, ^refusal}} =
             Provider.handle("mcp_servers", admin, %{
               "action" => "update",
               "name" => "literal",
               "epoch" => literal.epoch,
               "config" => naming.("gh-token")
             })

    assert {:ok, %{epoch: 1, config_json: unchanged}} =
             Arca.McpServerStorage.get(actor, "literal")

    refute unchanged =~ "gh-token"

    # A row naming it underneath is refused at sync, in the reader's words,
    # before its env is sealed or anything reaches the service.
    underneath = stdio_row(ctx, "underneath")

    assert {:error, :disclosure_refused} =
             Programs.hold(%{athanor_id: ctx.athanor_id, server_id: underneath.id, epoch: 1})

    refute_receive {:control, "sync", _sync, _fields}, 200
    refute_received {:sealed_env, _server, _env}

    # Its server process and its Test answer say why, never which entry.
    assert {:error, connect_sentence} = Servers.ensure_started(underneath, ctx)
    assert connect_sentence == Sanctum.Refusals.render(:disclosure_refused)

    assert {:ok, %{status: "error", error: sentence}} =
             Provider.handle("mcp_servers", admin, %{"action" => "test", "name" => "underneath"})

    assert sentence == Sanctum.Refusals.render(:disclosure_refused)
    refute sentence =~ "gh-token"
    refute_receive {:control, "sync", _sync, _fields}, 200

    # Nothing of the entry was unsealed.
    assert {:ok, %{last_used_at: nil}} = Arca.VaultStorage.get(actor, attached.id)

    # A disclosed entry is admitted at create and reaches the backend's env.
    vault_entry(ctx, %{name: "gh-disclosed"})

    assert {:ok, %{status: "ready"}} =
             Provider.handle("mcp_servers", admin, %{
               "action" => "create",
               "name" => "disclosed",
               "config" => naming.("gh-disclosed")
             })

    assert_receive {:sealed_env, _server, %{"github" => %{"GITHUB_TOKEN" => @secret}}}, 2_000
  end

  test "a disclosed entry beside an attach-only one is not unsealed: the sync is refused first",
       %{ctx: ctx, fake: fake} do
    start_controller(fake)
    disclosed = vault_entry(ctx)
    vault_entry(ctx, %{name: "gh-attached", disclose: false})

    # The disclosed entry's variable sorts first, so a resolution that
    # unsealed as it went would have read it before meeting the other.
    row =
      stdio_row(ctx, "mixed", %{
        "A_TOKEN" => "vault:gh-token",
        "B_TOKEN" => "vault:gh-attached"
      })

    assert {:error, :disclosure_refused} =
             Programs.hold(%{athanor_id: ctx.athanor_id, server_id: row.id, epoch: 1})

    assert {:ok, %{last_used_at: nil}} =
             Arca.VaultStorage.get(Sanctum.Context.actor(ctx), disclosed.id)

    refute_receive {:control, "sync", _sync, _fields}, 200
    refute_received {:sealed_env, _server, _env}

    # An entry that is not there refuses the sync alike, the disclosed one
    # still unread.
    absent = stdio_row(ctx, "absent", %{"A_TOKEN" => "vault:gh-token", "B_TOKEN" => "vault:nope"})

    assert {:error, {:env_unresolved, "github", "B_TOKEN"}} =
             Programs.hold(%{athanor_id: ctx.athanor_id, server_id: absent.id, epoch: 1})

    assert {:ok, %{last_used_at: nil}} =
             Arca.VaultStorage.get(Sanctum.Context.actor(ctx), disclosed.id)
  end

  # A definition a member wrote names an entry of its own athanor and
  # nothing else (`Sanctum.VaultReader`): an env naming, by name, only an
  # entry another person's athanor holds and shares with everyone finds no
  # entry of that name, and the shared entry is neither unsealed nor used.
  test "an env naming only another athanor's shared entry is unresolved and reads nothing of it",
       %{ctx: ctx, fake: fake} do
    start_controller(fake)
    entry_name = "shared-only-#{System.unique_integer([:positive])}"
    shared = shared_entry!(entry_name)

    assert {:error, :not_found} =
             Arca.VaultStorage.get_by_name(Sanctum.Context.actor(ctx), entry_name)

    before = shared_state(shared)
    assert {%{status: "active", last_used_at: nil}, %{status: "active"}, _usage} = before
    row = stdio_row(ctx, "shared-named", %{"GITHUB_TOKEN" => "vault:" <> entry_name})

    assert {:error, {:env_unresolved, "github", "GITHUB_TOKEN"}} =
             Programs.hold(%{athanor_id: ctx.athanor_id, server_id: row.id, epoch: 1})

    refute_receive {:control, "sync", _sync, _fields}, 200
    refute_received {:sealed_env, _server, _env}

    # The reader the sync would unseal through, asked directly: no entry of
    # the athanor, nothing unsealed. The sync above refuses before it
    # reaches it.
    assert {:error, :not_found} = Sanctum.VaultReader.unseal_disclosed(ctx.athanor_id, entry_name)
    assert shared_state(shared) == before
  end

  test "get reports what the service runs for a stdio server", %{ctx: ctx, fake: fake} do
    start_controller(fake)
    row = stdio_row(ctx, "described", %{"NODE_ENV" => "production"})
    connect(ctx, row)
    admin = %{ctx | permissions: MapSet.new([:*])}

    assert {:ok,
            %{transport: "stdio", epoch: 1, status: "ready", programs: [%{"name" => "github"}]}} =
             Provider.handle("mcp_servers", admin, %{
               "action" => "get",
               "name" => "described"
             })

    assert_receive {:control, "status", %{"owners" => [%{"server" => server}]}, _fields}, 2_000
    assert server == row.id
  end

  test "a command that expands a vault-bound name is saved with its warning, and its backends start",
       %{ctx: ctx, fake: fake} do
    start_controller(fake)
    vault_entry(ctx)
    admin = %{ctx | permissions: MapSet.new([:*])}
    actor = Sanctum.Context.actor(ctx)

    config = fn command ->
      %{
        "transport" => "stdio",
        "backends" => [
          %{
            "name" => "github",
            "command" => command,
            "env" => %{"GITHUB_TOKEN" => "vault:gh-token"}
          }
        ]
      }
    end

    expanding = ~s(npx -y @modelcontextprotocol/server-github --token "$GITHUB_TOKEN")

    warning =
      "Backend 'github' expands GITHUB_TOKEN, a vault-bound env name, in its command: the " <>
        "value is placed on the command line, where every process on the backends service, " <>
        "other athanors' backends included, can read it; the safe route is to let the " <>
        "program read it from its environment."

    log =
      capture_log(fn ->
        assert {:ok, %{status: "ready", warnings: [^warning]}} =
                 Provider.handle("mcp_servers", admin, %{
                   "action" => "create",
                   "name" => "expanding",
                   "config" => config.(expanding)
                 })
      end)

    # The definition is stored as written, its backends run with the value
    # in their env, and the start says so once in the log.
    assert {:ok, %{epoch: 1} = row} = Arca.McpServerStorage.get(actor, "expanding")
    assert [%{"command" => ^expanding}] = Arca.McpServerStorage.config(row)["backends"]
    assert_receive {:control, "sync", %{"e" => 1}, _fields}, 2_000
    assert_receive {:sealed_env, _server, %{"github" => %{"GITHUB_TOKEN" => @secret}}}, 2_000
    assert [_once] = Regex.scan(~r/starts with a warning: #{Regex.escape(warning)}/, log)

    # A later reader sees it on the server.
    assert {:ok, %{warnings: [^warning]}} =
             Provider.handle("mcp_servers", admin, %{"action" => "get", "name" => "expanding"})

    # An update keeps the warning while the command expands the name, and
    # drops it once the program reads the value from its environment.
    update = fn epoch, command ->
      Provider.handle("mcp_servers", admin, %{
        "action" => "update",
        "name" => "expanding",
        "epoch" => epoch,
        "config" => config.(command)
      })
    end

    assert capture_log(fn ->
             assert {:ok, %{status: "ready", warnings: [^warning], epoch: 2}} =
                      update.(1, expanding <> " --stdio")
           end) =~ "starts with a warning"

    refute capture_log(fn ->
             assert {:ok, %{status: "ready", warnings: [], epoch: 3}} =
                      update.(2, "npx -y @modelcontextprotocol/server-github")
           end) =~ "starts with a warning"

    assert {:ok, %{warnings: []}} =
             Provider.handle("mcp_servers", admin, %{"action" => "get", "name" => "expanding"})
  end

  test "a stored row whose command places a vault-bound value on the command line syncs at start",
       %{ctx: ctx, fake: fake} do
    start_controller(fake)
    vault_entry(ctx)

    {:ok, row} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: "stored",
        transport: "stdio",
        url: nil,
        config_json:
          Jason.encode!(%{
            "backends" => [
              %{
                "name" => "github",
                "command" => "npx server --token $GITHUB_TOKEN --at `date`",
                "env" => %{"GITHUB_TOKEN" => "vault:gh-token", "NODE_TOKEN" => "vault:gh-token"}
              }
            ]
          })
      })

    owner = %{athanor_id: ctx.athanor_id, server_id: row.id, epoch: row.epoch}

    log =
      capture_log(fn ->
        assert {:ok, %{epoch: epoch}} = Programs.hold(owner)
        assert epoch == row.epoch
      end)

    assert_received {:control, "sync", %{"e" => e}, _fields}
    assert e == row.epoch

    assert_received {:sealed_env, _server,
                     %{"github" => %{"GITHUB_TOKEN" => @secret, "NODE_TOKEN" => @secret}}}

    assert log =~ "starts with a warning: Backend 'github' expands GITHUB_TOKEN, "

    assert log =~
             ~s(starts with a warning: Backend 'github' has "`" in its command beside the vault-bound NODE_TOKEN: )

    Programs.release(owner)
  end

  # Every session message the script reported so far, dropped from the
  # mailbox.
  defp flush_sessions do
    receive do
      {:session, _type, _message, _fields} -> flush_sessions()
      {:invoke, _method, _fields} -> flush_sessions()
    after
      0 -> :ok
    end
  end

  defp pipe_row(ctx, name, over \\ %{}) do
    {:ok, row} =
      Arca.McpServerStorage.insert(
        Sanctum.Context.actor(ctx),
        Map.merge(
          %{
            cap: 0,
            name: name,
            transport: "pipe",
            url: nil,
            home: "kept",
            memory_bytes: 1_073_741_824,
            home_max_bytes: 2_147_483_648,
            login_command: "claude auth login",
            config_json:
              Jason.encode!(%{
                "backends" => [
                  %{
                    "name" => "claude",
                    "command" => "npx -y @anthropic-ai/claude-code",
                    "env" => %{}
                  }
                ]
              })
          },
          over
        )
      )

    row
  end

  # A login entry of the athanor naming `program`; its id is its home's.
  defp login_entry(ctx, name, program) do
    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{name: name, kind: "login", program: program})

    entry.id
  end

  describe "sessions" do
    # The scripted service keys, ends and idles sessions as Locus does.
    defp held(ctx, fake, name) do
      start_controller(fake)
      row = stdio_row(ctx, name, %{"NODE_ENV" => "production"})

      {:ok, grant} =
        Programs.hold(%{athanor_id: ctx.athanor_id, server_id: row.id, epoch: row.epoch})

      grant
    end

    defp opened(grant, home_id, mode) do
      {:ok, answer} =
        Opus.Programs.Session.open(grant, %{
          program: "github",
          home_id: home_id,
          key: "k",
          mode: mode,
          argv: []
        })

      answer
    end

    test "the service keys a session by its program, home, key and mode", %{ctx: ctx, fake: fake} do
      grant = held(ctx, fake, "keyed")
      run = opened(grant, "vlt_keyed", :run)
      assert %{resumed: true, session: same} = opened(grant, "vlt_keyed", :run)
      assert same == run.session

      assert %{resumed: false, session: sign_in} = opened(grant, "vlt_keyed", :sign_in)
      assert %{resumed: false, session: other_home} = opened(grant, "vlt_other", :run)
      assert Enum.uniq([run.session, sign_in, other_home]) == [run.session, sign_in, other_home]
    end

    test "a reset of a home ends every session of that home", %{ctx: ctx, fake: fake} do
      grant = held(ctx, fake, "reset")
      %{session: in_home} = opened(grant, "vlt_reset", :run)
      %{session: elsewhere} = opened(grant, "vlt_spared", :run)

      assert :ok = Programs.home(ctx.athanor_id, "vlt_reset", :reset)

      assert {:ok, %{running: false}} = Opus.Programs.Session.recv(grant, in_home, 0, 0)
      assert {:ok, %{running: true}} = Opus.Programs.Session.recv(grant, elsewhere, 0, 0)
    end

    test "a waiting recv counts as use at its arrival alone, so idle ends the session it waits on",
         %{ctx: ctx, fake: fake} do
      grant = held(ctx, fake, "waiting")
      %{session: session} = opened(grant, nil, :run)
      Scripted.set(fake, :idle_ms, 300)

      started = System.monotonic_time(:millisecond)
      assert {:ok, %{running: false}} = Opus.Programs.Session.recv(grant, session, 0, 3_000)
      assert System.monotonic_time(:millisecond) - started < 2_500
    end

    test "a stdio session is read only while a call is outstanding, so idle ends it and the next call initializes it again",
         %{ctx: ctx, fake: fake} do
      start_controller(fake)
      row = stdio_row(ctx, "idling", %{"NODE_ENV" => "production"})
      pid = connect(ctx, row)
      assert {:ok, _} = Emissary.External.Server.call_tool(pid, "github__search", %{})
      assert_receive {:invoke, "tools/call", _fields}, 2_000

      # Answered, nothing is outstanding: no reader polls the session, so it
      # sees no activity of this server's.
      Process.sleep(100)
      flush_sessions()
      refute_receive {:session, "recv", _message, _fields}, 400

      # The service ends it for idleness; the next call finds it ended, opens
      # it again and initializes the backend afresh before calling.
      Scripted.set(fake, :idle_ms, 200)
      Process.sleep(300)

      assert {:ok, %{"content" => [%{"text" => "found"}]}} =
               Emissary.External.Server.call_tool(pid, "github__search", %{})

      assert_receive {:session, "open", %{"key" => "mcp"}, _fields}, 2_000
      assert_receive {:invoke, "initialize", _fields}, 2_000
      assert_receive {:invoke, "tools/call", _fields}, 2_000
      assert [_ended, _running] = Map.values(Scripted.sessions(fake, row.id))
    end

    test "a session that ends fails the call awaiting it, and the next call opens it again",
         %{ctx: ctx, fake: fake} do
      start_controller(fake)
      row = stdio_row(ctx, "ending", %{"NODE_ENV" => "production"})
      pid = connect(ctx, row)
      Scripted.set(fake, :silent, ["tools/call"])

      call = Task.async(fn -> Emissary.External.Server.call_tool(pid, "github__search", %{}) end)
      assert_receive {:invoke, "tools/call", _fields}, 2_000
      Scripted.end_sessions(fake, row.id)

      assert {:error, sentence} = Task.await(call, 5_000)
      assert sentence =~ "ended before it answered"

      Scripted.set(fake, :silent, [])
      assert {:ok, _} = Emissary.External.Server.call_tool(pid, "github__search", %{})
      assert_receive {:invoke, "initialize", _fields}, 2_000
    end

    test "a pipe row syncs its program with its settings and has no MCP process",
         %{ctx: ctx, fake: fake} do
      start_controller(fake)
      row = pipe_row(ctx, "claude")
      owner = %{athanor_id: ctx.athanor_id, server_id: row.id, epoch: row.epoch}

      assert {:ok, %{epoch: 1, url: url}} = Programs.hold(owner)
      assert url =~ LocusBackends.route(:session)

      assert_receive {:control, "sync",
                      %{
                        "programs" => [
                          %{
                            "name" => "claude",
                            "home" => "kept",
                            "memory_bytes" => 1_073_741_824,
                            "home_max_bytes" => 2_147_483_648,
                            "login_command" => "claude auth login",
                            "env_names" => []
                          }
                        ]
                      }, _fields},
                     2_000

      assert {:error, {:invalid_argument, sentence}} = Servers.ensure_started(row, ctx)
      assert sentence =~ "pipe program"
      Programs.release(owner)
      assert_released(row, 1)
    end

    test "a kept stdio row runs its sessions in its login entry's home, and connects to none without it",
         %{ctx: ctx, fake: fake} do
      start_controller(fake)

      {:ok, row} =
        Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
          cap: 0,
          name: "gh",
          transport: "stdio",
          url: nil,
          home: "kept",
          login_entry_id: "vlt_missing",
          login_command: "gh auth login",
          config_json:
            Jason.encode!(%{
              "backends" => [
                %{
                  "name" => "github",
                  "command" => "gh mcp",
                  "env" => %{"NODE_ENV" => "production"}
                }
              ]
            })
        })

      assert {:error, sentence} = Servers.ensure_started(row, ctx)
      assert sentence =~ "login entry"
      refute_received {:control, "sync", _sync, _fields}

      # Another program's login entry is refused alike.
      other = login_entry(ctx, "claude-login", "claude")

      {:ok, row} =
        Arca.McpServerStorage.update(Sanctum.Context.actor(ctx), "gh", %{login_entry_id: other})

      assert {:error, sentence} = Servers.ensure_started(row, ctx)
      assert sentence =~ "login entry"

      gh = login_entry(ctx, "gh-login", "gh")

      {:ok, row} =
        Arca.McpServerStorage.update(Sanctum.Context.actor(ctx), "gh", %{login_entry_id: gh})

      assert {:ok, [%{"name" => "github__search"}]} = Servers.ensure_started(row, ctx)
      assert_receive {:session, "open", %{"home_id" => ^gh, "mode" => "run"}, _}, 2_000
      refute_received {:session, "open", %{"home_id" => ^other}, _fields}
    end
  end

  describe "sign-in and homes" do
    setup %{ctx: ctx, fake: fake} do
      controller = start_controller(fake)
      row = pipe_row(ctx, "claude")
      entry = login_entry(ctx, "claude-login", "claude")
      admin = %{ctx | permissions: MapSet.new([:*])}
      {:ok, controller: controller, row: row, admin: admin, entry: entry}
    end

    test "a sign-in runs the login command in the entry's home and relays its lines both ways",
         %{ctx: ctx, fake: fake, row: row, admin: admin, entry: entry} do
      assert {:ok, %{session: token, program: "claude", entry: ^entry}} =
               Provider.handle("mcp_servers", admin, %{
                 "action" => "sign_in",
                 "name" => "claude",
                 "entry" => "claude-login"
               })

      assert_receive {:session, "open", %{"mode" => "sign_in", "home_id" => ^entry, "argv" => []},
                      _},
                     2_000

      # A line the program wrote before anyone attached is kept for them.
      Scripted.write(fake, row.id, "Open https://claude.ai/oauth and paste the code:")
      Process.sleep(100)

      # Only the caller that started it attaches.
      other = %{admin | user_id: "someone-else"}
      assert {:error, :not_yours} = Programs.sign_in_attach(other, token, self())
      assert :ok = Programs.sign_in_attach(admin, token, self())

      assert_receive {Opus.Programs, ^token, {:lines, ["Open https://claude.ai/oauth" <> _]}},
                     2_000

      assert :ok = Programs.sign_in_send(admin, token, "code-1234")
      assert_receive {:session, "send", %{"lines" => ["code-1234"]}, _fields}, 2_000

      # The command ends by a signal: the subscriber is told, and the owner
      # released.
      Scripted.end_sessions(fake, row.id)
      assert_receive {Opus.Programs, ^token, {:ended, {:exited, nil}}}, 3_000
      assert_released(row, 1)
      refute ctx == nil
    end

    test "a needs_reauth entry signed in with an exit 0 is active again, and with exit 1 stays as it is",
         %{ctx: ctx, fake: fake, row: row, admin: admin, entry: entry} do
      actor = Sanctum.Context.actor(ctx)
      {:ok, _} = Arca.VaultStorage.set_status(actor, entry, "needs_reauth")

      sign_in = fn ->
        assert {:ok, %{session: token}} =
                 Provider.handle("mcp_servers", admin, %{
                   "action" => "sign_in",
                   "name" => "claude",
                   "entry" => entry
                 })

        assert :ok = Programs.sign_in_attach(admin, token, self())
        token
      end

      token = sign_in.()
      Scripted.end_sessions(fake, row.id, 1)
      assert_receive {Opus.Programs, ^token, {:ended, {:exited, 1}}}, 3_000
      assert_released(row, 1)
      assert {:ok, %{status: "needs_reauth"}} = Arca.VaultStorage.get(actor, entry)

      # A mount still refuses it meanwhile: only a sign-in admits it.
      assert {:error, {:entry_unavailable, "needs_reauth"}} =
               Sanctum.Mount.login_entry(ctx, entry, "claude")

      token = sign_in.()
      Scripted.end_sessions(fake, row.id, 0)
      assert_receive {Opus.Programs, ^token, {:ended, :signed_in}}, 3_000
      assert_released(row, 1)
      assert {:ok, %{status: "active"}} = Arca.VaultStorage.get(actor, entry)
    end

    test "a sign-in refuses an entry that is no login entry for the program, and a scratch program",
         %{ctx: ctx, admin: admin, entry: entry} do
      login_entry(ctx, "other-login", "other")

      assert {:error, {:invalid_argument, refusal}} =
               Provider.handle("mcp_servers", admin, %{
                 "action" => "sign_in",
                 "name" => "claude",
                 "entry" => "other-login"
               })

      assert refusal =~ "no active login entry"
      refute_received {:session, "open", _message, _fields}

      pipe_row(ctx, "scratchy", %{home: "scratch", home_max_bytes: nil})

      assert {:error, {:invalid_argument, refusal}} =
               Provider.handle("mcp_servers", admin, %{
                 "action" => "sign_in",
                 "name" => "scratchy",
                 "entry" => entry
               })

      assert refusal =~ "no sign-in"
      refute_received {:session, "open", _message, _fields}
    end

    test "reset_home empties the entry's kept home through the box",
         %{admin: admin, entry: entry} do
      assert {:ok, %{reset: ^entry}} =
               Provider.handle("mcp_servers", admin, %{
                 "action" => "reset_home",
                 "entry" => entry
               })

      assert_receive {:control, "home", %{"op" => "reset", "home_id" => ^entry, "athanor" => _},
                      _},
                     2_000

      assert {:error, {:not_found, "Login entry", "vlt_none"}} =
               Provider.handle("mcp_servers", admin, %{
                 "action" => "reset_home",
                 "entry" => "vlt_none"
               })
    end

    test "a retire that does not land is sent again on every tick until it does",
         %{ctx: ctx, fake: fake, controller: controller} do
      Scripted.refuse_once(fake, "home", "unavailable")
      assert {:error, :backends_unavailable} = Programs.home(ctx.athanor_id, "vlt_gone", :retire)
      assert_receive {:control, "home", %{"op" => "retire"}, _fields}, 2_000
      assert %{homes: homes} = await_idle(controller)
      assert %{op: :retire} = homes[{ctx.athanor_id, "vlt_gone"}]

      tick(controller)
      assert_receive {:control, "home", %{"op" => "retire", "home_id" => "vlt_gone"}, _}, 2_000
      assert %{homes: homes} = await_idle(controller)
      assert homes == %{}
    end

    test "a deleted login entry's home is retired, and so is every one of an archived athanor",
         %{ctx: ctx, entry: entry} do
      Prima.Test.Env.put_app_env(:cyfr, :external_server_reconciler_enabled, true)
      start_supervised!(Emissary.External.Reconciler)

      Cyfr.Bus.broadcast_global(
        Cyfr.Bus.vault_changed_global(),
        %Cyfr.Bus.VaultEntryChanged{
          athanor_id: ctx.athanor_id,
          entry_id: entry,
          name: "claude-login",
          kind: :delete
        }
      )

      assert_receive {:control, "home", %{"op" => "retire", "home_id" => ^entry}, _}, 3_000

      second = login_entry(ctx, "second-login", "claude")

      Cyfr.Bus.broadcast_global(
        Cyfr.Bus.athanor_archived_global(),
        Cyfr.Bus.AthanorArchived.new(ctx.athanor_id)
      )

      retired =
        for _ <- 1..2 do
          assert_receive {:control, "home", %{"op" => "retire", "home_id" => id}, _}, 3_000
          id
        end

      assert Enum.sort(retired) == Enum.sort([entry, second])
    end
  end

  # The session's close reaches the service, and only then its owner's
  # release: whichever of the two came first is the one received first.
  defp assert_closed_then_released(row, session, wait \\ 3_000) do
    first =
      receive do
        {:session, "close", %{"session" => ^session}, _fields} -> :close
        {:control, "release", _message, _fields} -> :release
      after
        wait -> flunk("neither the session's close nor its owner's release arrived")
      end

    assert first == :close, "the owner's release outran the session's close"
    assert_released(row, 1)
  end

  describe "pipes" do
    setup %{ctx: ctx} do
      row = pipe_row(ctx, "claude")
      entry = login_entry(ctx, "claude-login", "claude")
      {:ok, row: row, entry: entry}
    end

    test "a session is the row's and the key's: opened for one attempt, attached to by the next, started again once ended",
         %{ctx: ctx, fake: fake, row: row, entry: entry} do
      start_controller(fake)

      assert {:ok, %{session: first, resumed: false}} =
               Programs.pipe_open(row, entry, "pipe-k1", ["--resume", "s1"], "att_1")

      assert_receive {:session, "open",
                      %{
                        "mode" => "run",
                        "home_id" => ^entry,
                        "key" => "pipe-k1",
                        "argv" => ["--resume", "s1"]
                      }, _},
                     2_000

      # A repeat by the same attempt answers as the first did, though the
      # box now attaches to the running session.
      assert {:ok, %{session: ^first, resumed: false}} =
               Programs.pipe_open(row, entry, "pipe-k1", ["--resume", "s1"], "att_1")

      assert {:ok, %{session: ^first, resumed: true}} =
               Programs.pipe_open(row, entry, "pipe-k1", ["--resume", "s1"], "att_2")

      assert :ok = Programs.pipe_send(ctx.athanor_id, "att_2", first, ["hello"])
      assert_receive {:session, "send", %{"lines" => ["hello"], "session" => ^first}, _}, 2_000
      Scripted.write(fake, row.id, "world")

      assert {:ok, %{lines: [%{text: "world"} = line], dropped: 0, running: true}} =
               Programs.pipe_recv(ctx.athanor_id, "att_2", first, 0, 1_000)

      # Read again by the same `after`, the same line.
      assert {:ok, %{lines: [^line]}} = Programs.pipe_recv(ctx.athanor_id, "att_1", first, 0, 0)

      # Only an attempt that opened the session uses it, and only in its
      # own athanor.
      flush_sessions()
      assert {:error, :denied} = Programs.pipe_send(ctx.athanor_id, "att_3", first, ["x"])
      assert {:error, :denied} = Programs.pipe_recv(ctx.athanor_id, "att_3", first, 0, 0)
      assert {:error, :denied} = Programs.pipe_close(ctx.athanor_id, "att_3", first)
      assert {:error, :denied} = Programs.pipe_send("ath_other", "att_1", first, ["x"])
      refute_received {:session, _type, _message, _fields}

      # Its program ends: a read says so, and the next open starts it again.
      Scripted.end_sessions(fake, row.id)

      assert {:ok, %{running: false}} =
               Programs.pipe_recv(ctx.athanor_id, "att_2", first, line.seq, 0)

      assert {:ok, %{session: second, resumed: false}} =
               Programs.pipe_open(row, entry, "pipe-k1", ["--resume", "s1"], "att_2")

      refute second == first

      # The ended session is no one's any more: no lines, not running.
      assert {:ok, %{lines: [], dropped: 0, running: false}} =
               Programs.pipe_recv(ctx.athanor_id, "att_1", first, 0, 0)

      assert {:error, :ended} = Programs.pipe_send(ctx.athanor_id, "att_1", first, ["x"])
    end

    test "a close ends the session and releases the owner; a repeat is harmless",
         %{ctx: ctx, fake: fake, row: row, entry: entry} do
      start_controller(fake)
      assert {:ok, %{session: session}} = Programs.pipe_open(row, entry, "pipe-k", [], "att_1")

      assert :ok = Programs.pipe_close(ctx.athanor_id, "att_1", session)
      assert_closed_then_released(row, session)
      assert :ok = Programs.pipe_close(ctx.athanor_id, "att_1", session)

      assert {:ok, %{lines: [], running: false}} =
               Programs.pipe_recv(ctx.athanor_id, "att_1", session, 0, 0)
    end

    test "a session no attempt uses for the idle period ends, and its owner is released",
         %{fake: fake, row: row, entry: entry} do
      start_controller(fake, idle_ms: 200)
      assert {:ok, %{session: session}} = Programs.pipe_open(row, entry, "pipe-k", [], "att_1")
      assert_closed_then_released(row, session, 5_000)
      assert Programs.mounts() == []
    end

    test "a login entry's revoke ends every session in its home, and no other",
         %{ctx: ctx, fake: fake, row: row, entry: entry} do
      Prima.Test.Env.put_app_env(:cyfr, :external_server_reconciler_enabled, true)
      start_supervised!(Emissary.External.Reconciler)
      start_controller(fake)
      other = login_entry(ctx, "claude-second", "claude")

      assert {:ok, %{session: mine}} = Programs.pipe_open(row, entry, "pipe-k", [], "att_1")
      assert {:ok, %{session: kept}} = Programs.pipe_open(row, other, "pipe-k", [], "att_1")
      flush_sessions()

      assert {:ok, _} = Sanctum.Vault.revoke(ctx, entry)
      assert_receive {:session, "close", %{"session" => ^mine}, _}, 3_000
      refute_received {:session, "close", %{"session" => ^kept}, _}

      assert :ok = Programs.pipe_send(ctx.athanor_id, "att_1", kept, ["still here"])
      assert {:error, :ended} = Programs.pipe_send(ctx.athanor_id, "att_1", mine, ["gone"])
    end

    test "a sweep ends a session whose entry changed with no signal said, and no other",
         %{ctx: ctx, fake: fake, row: row, entry: entry} do
      start_controller(fake)
      other = login_entry(ctx, "claude-second", "claude")
      assert {:ok, %{session: mine}} = Programs.pipe_open(row, entry, "pipe-k", [], "att_1")
      assert {:ok, %{session: kept}} = Programs.pipe_open(row, other, "pipe-k", [], "att_1")

      assert [{ctx.athanor_id, entry, "claude"}, {ctx.athanor_id, other, "claude"}] |> Enum.sort() ==
               Enum.sort(Programs.mounts())

      flush_sessions()
      {:ok, _} = Arca.VaultStorage.set_status(Sanctum.Context.actor(ctx), entry, "needs_reauth")
      assert :ok = Emissary.External.Reconciler.sweep_mounts()

      assert_receive {:session, "close", %{"session" => ^mine}, _}, 3_000
      refute_received {:session, "close", %{"session" => ^kept}, _}
      assert [{_athanor, ^other, "claude"}] = Programs.mounts()
    end

    test "a send whose connection is reset after it arrived is uncertain, never safe to repeat",
         %{ctx: ctx, fake: fake, row: row, entry: entry} do
      start_controller(fake)
      assert {:ok, %{session: session}} = Programs.pipe_open(row, entry, "pipe-k", [], "att_1")
      flush_sessions()
      Scripted.set(fake, :reset_send, true)

      assert {:error, :uncertain} =
               Programs.pipe_send(ctx.athanor_id, "att_1", session, ["once"])

      # It reached the box.
      assert_received {:session, "send", %{"lines" => ["once"]}, _}
    end

    test "a holder killed has its session closed by the box, its row's other holder untouched",
         %{ctx: ctx, fake: fake, row: row, entry: entry} do
      start_controller(fake)
      assert {:ok, %{session: first}} = Programs.pipe_open(row, entry, "pipe-a", [], "att_1")
      assert {:ok, %{session: second}} = Programs.pipe_open(row, entry, "pipe-b", [], "att_1")
      [{pid, _}] = Registry.lookup(Opus.Programs.Registry, {:pipe_session, first})
      flush_sessions()

      # Killed, it runs no terminate/2: well before the idle period, the box
      # closes its program all the same, and keeps the owner for the other.
      Process.exit(pid, :kill)
      assert_receive {:session, "close", %{"session" => ^first}, _}, 2_000
      refute_receive {:control, "release", _message, _fields}, 300
      assert :ok = Programs.pipe_send(ctx.athanor_id, "att_1", second, ["still here"])
    end

    test "one deadline covers the owner's acquisition and the open; nothing of a late open runs",
         %{fake: fake, row: row, entry: entry} do
      start_controller(fake)

      # Scaled from a 15 s acquisition and a 17 s open against a 30 s window:
      # each fits alone, together they do not.
      deadline = System.system_time(:millisecond) + 3_000
      Scripted.hold(fake, "sync")
      Scripted.hold(fake, "open")

      opening =
        Task.async(fn -> Programs.pipe_open(row, entry, "pipe-k", [], "att_1", deadline) end)

      assert_receive {:held, "sync", sync}, 2_000
      Process.sleep(1_500)
      send(sync, :go)
      assert_receive {:held, "open", open}, 2_000
      Process.sleep(1_700)
      send(open, :go)

      assert {:error, :deadline} = Task.await(opening, 5_000)
      assert System.system_time(:millisecond) < deadline + 2_000

      # No holder keeps it, and the owner is released with it.
      assert_released(row, 1)
      assert Programs.mounts() == []
    end

    test "a holder killed before it hears the box's answer leaves the box its session to close",
         %{ctx: ctx, fake: fake, row: row, entry: entry} do
      start_controller(fake)
      assert {:ok, %{session: sibling}} = Programs.pipe_open(row, entry, "pipe-b", [], "att_1")
      flush_sessions()
      Scripted.hold(fake, "opened")

      opening =
        Task.async(fn -> Programs.pipe_open(row, entry, "pipe-a", [], "att_1") end)

      # The backend's session stands; its answer is on its way when the
      # holder that asked is killed.
      assert_receive {:held, "opened", answer}, 2_000
      key = {:pipe, row.athanor_id, row.id, row.epoch, entry, "pipe-a"}
      [{holder, _}] = Registry.lookup(Opus.Programs.Registry, key)
      Process.exit(holder, :kill)
      send(answer, :go)
      assert {:error, _} = Task.await(opening, 5_000)

      assert_receive {:session, "close", %{"session" => closed}, _}, 3_000
      refute closed == sibling
      refute_receive {:control, "release", _message, _fields}, 300
      assert :ok = Programs.pipe_send(ctx.athanor_id, "att_1", sibling, ["still here"])
    end

    test "a close refused once is owed by the box past its holder's release, and lands on the sweep",
         %{ctx: ctx, fake: fake, row: row, entry: entry} do
      controller = start_controller(fake)
      assert {:ok, %{session: _sibling}} = Programs.pipe_open(row, entry, "pipe-b", [], "att_1")
      assert {:ok, %{session: session}} = Programs.pipe_open(row, entry, "pipe-a", [], "att_1")
      flush_sessions()
      Scripted.refuse_once(fake, "close", "unavailable")

      # The holder closes and releases; the box's close is refused.
      assert :ok = Programs.pipe_close(ctx.athanor_id, "att_1", session)
      assert_receive {:session, "close", %{"session" => ^session}, _}, 2_000
      refute_receive {:control, "release", _message, _fields}, 300

      # The sweep sends it again, and the program ends.
      tick(controller)
      assert_receive {:session, "close", %{"session" => ^session}, _}, 2_000
      assert %{^session => %{running: false}} = Scripted.sessions(fake, row.id)
    end

    test "a late first answer never closes the session a second open of the key was given",
         %{ctx: ctx, fake: fake, row: row, entry: entry} do
      start_controller(fake)
      assert {:ok, %{session: _sibling}} = Programs.pipe_open(row, entry, "pipe-b", [], "att_0")
      flush_sessions()

      # The first open's session stands at the backend, its answer held
      # past its caller's deadline.
      Scripted.hold(fake, "opened")
      deadline = System.system_time(:millisecond) + 1_000

      first =
        Task.async(fn -> Programs.pipe_open(row, entry, "pipe-a", [], "att_1", deadline) end)

      assert_receive {:held, "opened", answer}, 2_000
      assert {:error, :deadline} = Task.await(first, 3_000)

      # A second open of the key is given the session.
      assert {:ok, %{session: session}} = Programs.pipe_open(row, entry, "pipe-a", [], "att_2")
      flush_sessions()

      # The first answer, late, closes nothing of it.
      send(answer, :go)
      refute_receive {:session, "close", %{"session" => ^session}, _}, 1_000
      assert :ok = Programs.pipe_send(ctx.athanor_id, "att_2", session, ["intact"])
    end

    test "a success queued before the deadline and handled after it is closed, never given",
         %{fake: fake, row: row, entry: entry} do
      start_controller(fake)
      assert {:ok, %{session: sibling}} = Programs.pipe_open(row, entry, "pipe-b", [], "att_0")
      flush_sessions()
      box = GenServer.whereis(Programs.via("local"))

      Scripted.hold(fake, "opened")
      deadline = System.system_time(:millisecond) + 1_500

      opening =
        Task.async(fn -> Programs.pipe_open(row, entry, "pipe-a", [], "att_1", deadline) end)

      assert_receive {:held, "opened", answer}, 2_000

      # The answer reaches the box before the deadline, and is handled
      # only after it.
      :sys.suspend(box)
      send(answer, :go)
      Process.sleep(max(deadline - System.system_time(:millisecond), 0) + 300)
      :sys.resume(box)

      assert {:error, :deadline} = Task.await(opening, 3_000)
      assert_receive {:session, "close", %{"session" => closed}, _}, 3_000
      refute closed == sibling
    end

    test "a row that is disabled stands its sessions down", %{
      ctx: ctx,
      fake: fake,
      row: row,
      entry: entry
    } do
      controller = start_controller(fake)
      assert {:ok, %{session: session}} = Programs.pipe_open(row, entry, "pipe-k", [], "att_1")
      [{pid, _}] = Registry.lookup(Opus.Programs.Registry, {:pipe_session, session})
      monitor = Process.monitor(pid)

      {:ok, _} =
        Arca.McpServerStorage.update(Sanctum.Context.actor(ctx), "claude", %{enabled: false})

      tick(controller)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 3_000

      assert {:ok, %{lines: [], running: false}} =
               Programs.pipe_recv(ctx.athanor_id, "att_1", session, 0, 0)
    end
  end

  describe "status" do
    test "is nil for an owner the service runs nothing for, its entry for one it runs, and names no more owners than the service's bound",
         %{ctx: ctx, fake: fake} do
      start_controller(fake)
      assert {:ok, nil} = Programs.status(ctx.athanor_id, "mcp_nothing")
      assert_receive {:control, "status", %{"owners" => [%{"server" => "mcp_nothing"}]}, _}, 2_000

      row = stdio_row(ctx, "running", %{"NODE_ENV" => "production"})
      connect(ctx, row)

      assert {:ok, %{"e" => 1, "programs" => [%{"name" => "github", "home" => "scratch"}]}} =
               Programs.status(ctx.athanor_id, row.id)

      assert_receive {:control, "status", %{"owners" => owners}, _fields}, 2_000
      assert length(owners) <= LocusBackends.max_status_owners()
    end

    test "each refusal of the service is its typed result, and a service that cannot be reached is unavailable",
         %{ctx: ctx, fake: fake} do
      start_controller(fake)
      row = stdio_row(ctx, "bounded", %{"NODE_ENV" => "production"})
      connect(ctx, row)

      Scripted.refuse_once(fake, "status", "too_many_owners", 400)
      assert {:error, :too_many_owners} = Programs.status(ctx.athanor_id, row.id)

      Scripted.refuse_once(fake, "status", "status_too_large")
      assert {:error, :status_too_large} = Programs.status(ctx.athanor_id, row.id)

      Scripted.down(fake)
      assert {:error, :backends_unavailable} = Programs.status(ctx.athanor_id, row.id)

      Scripted.up(fake)
      assert {:ok, %{"e" => 1}} = Programs.status(ctx.athanor_id, row.id)
    end

    test "an answer the service did not bound is stopped at the answer bound and is status_too_large as well: neither read whole, emptied nor unavailable",
         %{ctx: ctx, fake: fake} do
      start_controller(fake)
      row = stdio_row(ctx, "verbose", %{"NODE_ENV" => "production"})
      connect(ctx, row)
      Scripted.set(fake, :stderr_bytes, LocusBackends.max_status_answer_bytes() + 1)
      assert {:error, :status_too_large} = Programs.status(ctx.athanor_id, row.id)

      Scripted.set(fake, :stderr_bytes, 0)
      assert {:ok, %{"e" => 1}} = Programs.status(ctx.athanor_id, row.id)
    end

    # The controller asks a status for at most `max_status_owners/0` owners
    # and reads its answer no further than `max_status_answer_bytes/0`
    # (`Prima.LocusBackends`): the bounds the service keeps.
    test "the bounds a status is asked and read within are the wire's, as its vector file states them" do
      bounds =
        Path.expand("../../../../tests/fixtures/locus_backends.json", __DIR__)
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("bounds")

      assert LocusBackends.max_status_owners() == bounds["max_status_owners"]
      assert LocusBackends.max_status_answer_bytes() == bounds["max_status_answer_bytes"]
    end

    test "a refused signature, and a refusal or an answer at another protocol version, are their own typed results",
         %{ctx: ctx, fake: fake} do
      start_controller(fake)
      row = stdio_row(ctx, "versioned", %{"NODE_ENV" => "production"})
      connect(ctx, row)

      Scripted.refuse_once(fake, "status", "unauthorized")
      assert {:error, :backends_refused_signature} = Programs.status(ctx.athanor_id, row.id)

      Scripted.refuse_once(fake, "status", "version")
      assert {:error, :protocol_mismatch} = Programs.status(ctx.athanor_id, row.id)

      Scripted.set(fake, :answer_version, LocusBackends.version() + 1)
      assert {:error, :protocol_mismatch} = Programs.status(ctx.athanor_id, row.id)

      # A code that is not the one its status carries reads as nothing.
      Scripted.set(fake, :answer_version, LocusBackends.version())
      Scripted.refuse_once(fake, "status", "too_many_owners", 409)
      assert {:error, {:backends_status, 409}} = Programs.status(ctx.athanor_id, row.id)

      assert {:ok, %{"e" => 1}} = Programs.status(ctx.athanor_id, row.id)
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
      assert %{inflight: {_ref, {:sync, _key}, spec}} = state = :sys.get_state(controller)
      for key <- keys, do: refute(inspect(spec, limit: :infinity) =~ rendered(key))

      # The state printed whole, spec and all, as any line that prints it
      # does: its own Inspect leaves the root and the derived keys out.
      printed = inspect(state, limit: :infinity, printable_limit: :infinity)
      assert printed =~ "inflight: {"
      for key <- keys, do: refute(printed =~ rendered(key))

      {:status, _pid, _module, items} = :sys.get_status(controller)

      assert %Opus.Programs.Box.State{
               root: "[REDACTED]",
               control_key: "[REDACTED]",
               seal_key: "[REDACTED]"
             } =
               status_state(items, Opus.Programs.Box.State)

      status = inspect(items, limit: :infinity, printable_limit: :infinity)
      for key <- keys, do: refute(status =~ rendered(key))

      # The report of a crash names the failed callback by its arity
      # (`Prima.LogFilter`): the state its frame carries, spec and all, is
      # never printed.
      log =
        capture_log(fn ->
          catch_exit(GenServer.call(controller, :no_such_call))
          Process.sleep(200)
        end)

      released = Process.monitor(held)
      send(held, :go)
      assert_receive {:DOWN, ^released, :process, ^held, _reason}, 5_000
      assert log =~ "Opus.Programs.Box.handle_call/3"
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
        url: "http://locus-backends:4101/locus/v1/backends/session",
        owner_key: :crypto.strong_rand_bytes(32),
        epoch: 1
      }

      spec = %{control_key: :crypto.strong_rand_bytes(32), seal_key: <<1>>, sealed: "x", seq: 7}

      headers = %{"authorization" => "Bearer #{@secret}"}

      reason =
        {:function_clause,
         [{Opus.Programs.Box, :handle_call, [:bogus, spec, [headers: headers]], []}]}

      assert %{
               message:
                 {Opus.Programs, :owner,
                  %{
                    owner_key: "[REDACTED]",
                    url: "http://locus-backends:4101/locus/v1/backends/session"
                  }},
               reason:
                 {:function_clause,
                  [
                    {Opus.Programs.Box, :handle_call,
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
               Opus.Programs.StatusRedaction.format_status(%{
                 message: {Opus.Programs, :owner, grant},
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

  # An attach-only entry named `entry_name` in another person's own vault,
  # at the destination these cases' entries name, and the owner's share of
  # it with everyone: the owner's context, the entry and the share.
  defp shared_entry!(entry_name) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "local|local|backends-owner-#{n}",
        provider: "local",
        name: "Owner #{n}"
      })

    own = Sanctum.Test.People.athanor!(user)
    owner = %{Sanctum.TestContext.local(:prism) | user_id: user.id, athanor_id: own.id}

    {:ok, entry} =
      Sanctum.TestContext.create_vault(owner, %{
        name: entry_name,
        kind: "api_key",
        fields: %{"token" => @secret},
        destination: Map.merge(@destination, %{"methods" => ["POST"], "paths" => ["/mcp"]})
      })

    {:ok, share} =
      Sanctum.TestContext.confirming(
        owner,
        &Sanctum.Shares.create(&1, %{entry_id: entry.id, audience: "everyone"})
      )

    %{owner: owner, entry: entry, share: share}
  end

  # The shared entry's stored row, the share's, and the share's use today,
  # as their owner reads them.
  defp shared_state(%{owner: owner, entry: entry, share: share}) do
    actor = Sanctum.Context.actor(owner)
    {:ok, entry_row} = Arca.VaultStorage.get(actor, entry.id)
    {:ok, share_row} = Arca.Shares.get(actor, share.id)
    {:ok, usage} = Arca.ShareUsage.usage(actor, share.id, 1)
    {entry_row, share_row, usage}
  end
end
