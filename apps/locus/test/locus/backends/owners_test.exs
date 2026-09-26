# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends.OwnersTest do
  @moduledoc """
  The owner table: the version rules of a sync, table-driven; `capacity`
  and `unavailable` told apart, and a pool read that never answers refused
  within its bound while the table goes on answering; a retirement seen twice, and a uid freed once; renew and
  `unknown`; reconcile and release; a lease lapsing and a backend going
  idle through a driven sweep, on a clock the test moves; a sync answered
  on admission with readiness through `rev`; the bound on backends per
  owner and on calls awaiting one backend. Backends run through the test
  environment's `Locus.DirectLauncher`; the pool is a stub the test sets.
  The probe (`fixtures/probe.mjs`) needs `node`; its cases are tagged
  `:requires_node`.
  """

  use ExUnit.Case, async: false

  alias Locus.Backends.{Backend, LeaseSweeper, Owners}

  @probe Path.expand("fixtures/probe.mjs", __DIR__)
  @athanor "ath_owners"
  @idle "exec cat >/dev/null"

  defmodule Pool do
    @moduledoc false
    # The pool a test sets: an answer, or `:hang` for a launcher that never
    # answers. Only the owners read the pool; backends launch through the
    # direct launcher.
    def pool_stats(agent, "backends") do
      case Agent.get(agent, & &1) do
        :hang -> Process.sleep(:infinity)
        answer -> answer
      end
    end
  end

  setup do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    pool = start_supervised!({Agent, fn -> pool(4) end}, id: :pool)
    clock = start_supervised!({Agent, fn -> 1_000_000 end}, id: :clock)
    {:ok, supervisor: supervisor, pool: pool, clock: clock}
  end

  defp pool(size, quarantined \\ 0),
    do: {:ok, %{size: size, free: size - quarantined, quarantined: quarantined}}

  defp start_owners(context, opts \\ []) do
    %{supervisor: supervisor, pool: pool, clock: clock} = context

    start_supervised!(
      {Owners,
       Keyword.merge(
         [
           boot: "bb_owners",
           launcher: Pool,
           launcher_server: pool,
           supervisor: supervisor,
           clock: fn -> Agent.get(clock, & &1) end,
           stop_grace_ms: 200,
           pool_timeout_ms: 500,
           backend_opts: [
             launcher: Locus.DirectLauncher,
             launcher_server: [],
             release_timeout_ms: 5_000,
             init_timeout_ms: 60_000
           ]
         ],
         opts
       )}
    )
  end

  defp advance(%{clock: clock}, ms), do: Agent.update(clock, &(&1 + ms))

  defp node! do
    {path, 0} = System.cmd("node", ["-e", "process.stdout.write(process.execPath)"])
    path
  end

  defp probe, do: ~s(exec "#{node!()}" "#{@probe}")

  # A control message at the next sequence of generation `g`.
  defp control(owners, g, message, open_env \\ nil) do
    fields = %{
      generation: g,
      seq: System.unique_integer([:positive, :monotonic]),
      cyfr_boot: "boot_test",
      boot: "bb_owners",
      ts: 0
    }

    Owners.control(owners, fields, message, open_env)
  end

  # A sync of `server` at `(g, e)` defining `backends`, `{name, command,
  # env}` each, its environment opened as given.
  defp sync(owners, server, {g, e}, backends, opts \\ []) do
    message = %{
      type: :sync,
      owner: %{athanor: @athanor, server: server},
      e: e,
      lease_ms: Keyword.get(opts, :lease_ms, 30_000),
      idle_ms: Keyword.get(opts, :idle_ms, 600_000),
      backends:
        for(
          {name, command, env} <- backends,
          do: %{name: name, command: command, env_names: Map.keys(env)}
        ),
      sealed: "c2VhbGVk"
    }

    env = Map.new(backends, fn {name, _command, env} -> {name, env} end)
    control(owners, g, message, fn -> {:ok, env} end)
  end

  defp idle_backends(count),
    do: for(i <- 1..count, do: {"b#{i}", @idle, %{}})

  defp invoke(server, {g, e}),
    do: %{athanor: @athanor, server: server, generation: g, epoch: e}

  defp held(owners), do: :sys.get_state(owners).owners

  defp wait_until(check, attempts \\ 200) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(25) && wait_until(check, attempts - 1)
    end
  end

  defp backend_pid(owners, server, version, name) do
    {:ok, %{backends: backends}} = Owners.admit(owners, invoke(server, version))
    {^name, pid} = List.keyfind(backends, name, 0)
    pid
  end

  describe "the version rules" do
    test "a sync lower, equal or higher than the held version, by the version rules",
         ctx do
      owners = start_owners(ctx)
      a = [{"alpha", @idle, %{"TOKEN" => "secret-token-a"}}]
      b = [{"beta", @idle, %{}}]

      assert {:ok, %{status: :starting, rev: 0, backends: [%{name: "alpha"}]}} =
               sync(owners, "srv", {2, 5}, a)

      # A lower generation never reaches the table: its control message is
      # below the high-water mark (`stale_control`).
      for {version, backends, expected} <- [
            {{2, 4}, a, {:error, :stale_epoch}},
            {{2, 1}, b, {:error, :stale_epoch}},
            {{2, 5}, b, {:error, :conflict}},
            {{2, 5}, a, :held}
          ] do
        case expected do
          :held ->
            assert {:ok, %{status: :starting, backends: [%{name: "alpha"}]}} =
                     sync(owners, "srv", version, backends)

          refusal ->
            assert refusal == sync(owners, "srv", version, backends), inspect(version)
        end
      end

      # The equal sync extended the lease and set the idle period.
      [%{idle_ms: 600_000}] = Map.values(held(owners))

      # Higher: the held version retired, then the new one admitted.
      assert {:ok, %{status: :starting, rev: 0, backends: [%{name: "beta"}]}} =
               sync(owners, "srv", {2, 6}, b)

      assert {:error, :stale_epoch} = Owners.admit(owners, invoke("srv", {2, 5}))
      assert {:ok, %{backends: [{"beta", _}]}} = Owners.admit(owners, invoke("srv", {2, 6}))
      assert {:error, :epoch_ahead} = Owners.admit(owners, invoke("srv", {2, 7}))
      assert {:error, :epoch_ahead} = Owners.admit(owners, invoke("srv", {3, 1}))
      assert {:error, :unknown_owner} = Owners.admit(owners, invoke("other", {2, 6}))

      # A higher generation replaces it again; the retired versions are gone
      # once their backends stop.
      assert {:ok, _} = sync(owners, "srv", {3, 1}, a)
      wait_until(fn -> map_size(held(owners)) == 1 end)
    end

    test "an equal sync while the owner drains is lapsed", ctx do
      owners = start_owners(ctx)
      a = [{"alpha", @idle, %{}}]

      assert {:ok, _} = sync(owners, "srv", {1, 1}, a, lease_ms: 1_000)
      advance(ctx, 1_000)
      :ok = LeaseSweeper.sweep(owners)

      assert {:error, :lapsed} = sync(owners, "srv", {1, 1}, a)
      assert {:error, :lapsed} = Owners.admit(owners, invoke("srv", {1, 1}))
    end

    test "an environment that is not the definitions' is refused before anything is retired",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "srv", {1, 1}, [{"alpha", @idle, %{"A" => "x"}}])

      message = %{
        type: :sync,
        owner: %{athanor: @athanor, server: "srv"},
        e: 2,
        lease_ms: 30_000,
        idle_ms: 60_000,
        backends: [%{name: "alpha", command: @idle, env_names: ["A"]}],
        sealed: "c2VhbGVk"
      }

      for opened <- [
            fn -> :error end,
            fn -> {:ok, %{}} end,
            fn -> {:ok, %{"alpha" => %{"B" => "x"}}} end,
            fn -> {:ok, %{"alpha" => %{"A" => 1}}} end,
            fn -> {:ok, %{"alpha" => %{"A" => "x"}, "beta" => %{}}} end
          ] do
        assert {:error, :bad_request} = control(owners, 1, message, opened)
      end

      assert {:ok, _} = Owners.admit(owners, invoke("srv", {1, 1}))
    end

    test "a control message at or below the high-water mark is stale", ctx do
      owners = start_owners(ctx)
      renew = %{type: :renew, lease_ms: 1_000, owners: []}
      fields = %{generation: 4, seq: 7, cyfr_boot: "b", boot: "bb_owners", ts: 0}

      assert :ok = Owners.fresh(owners, fields)
      assert {:ok, _} = Owners.control(owners, fields, renew)
      assert {:error, :stale_control} = Owners.fresh(owners, fields)
      assert {:error, :stale_control} = Owners.control(owners, fields, renew)
      assert {:error, :stale_control} = Owners.control(owners, %{fields | seq: 6}, renew)
      assert {:error, :stale_control} = Owners.control(owners, %{fields | generation: 3}, renew)
      assert {:ok, _} = Owners.control(owners, %{fields | generation: 5, seq: 0}, renew)
    end

    test "the backends one sync may define are bounded", ctx do
      owners = start_owners(ctx)
      Agent.update(ctx.pool, fn _ -> pool(64) end)
      max = Prima.LocusBackends.max_backends()

      assert {:error, :bad_request} = sync(owners, "srv", {1, 1}, idle_backends(max + 1))
      assert {:ok, %{backends: backends}} = sync(owners, "srv", {1, 2}, idle_backends(max))
      assert length(backends) == max
    end
  end

  describe "the uid pool" do
    test "a claim past the pool is capacity, a pool not answered unavailable, never confused",
         ctx do
      owners = start_owners(ctx)

      Agent.update(ctx.pool, fn _ -> pool(2) end)
      assert {:error, :capacity} = sync(owners, "a", {1, 1}, idle_backends(3))

      # The quarantined uids are no uids to hold.
      Agent.update(ctx.pool, fn _ -> pool(3, 1) end)
      assert {:error, :capacity} = sync(owners, "a", {1, 2}, idle_backends(3))

      Agent.update(ctx.pool, fn _ -> {:error, {:launcher_unavailable, :timeout}} end)
      assert {:error, :unavailable} = sync(owners, "a", {1, 3}, idle_backends(1))

      assert {:error, :unavailable} =
               control(owners, 1, %{type: :hello, g: 1, cyfr_boot: "boot_test"})

      Agent.update(ctx.pool, fn _ -> {:error, {:refused, "unknown_pool"}} end)
      assert {:error, :unavailable} = sync(owners, "a", {1, 4}, idle_backends(1))

      Agent.update(ctx.pool, fn _ -> pool(3) end)
      assert {:ok, _} = sync(owners, "a", {1, 5}, idle_backends(3))
      assert {:error, :capacity} = sync(owners, "b", {1, 1}, idle_backends(1))

      assert {:ok, %{boot: "bb_owners", pool: %{size: 3, free: 3}}} =
               control(owners, 1, %{type: :hello, g: 1, cyfr_boot: "boot_test"})
    end

    test "a pool read that never answers is unavailable within its bound, and the table answers meanwhile",
         ctx do
      owners = start_owners(ctx)
      Agent.update(ctx.pool, fn _ -> :hang end)

      pending = Task.async(fn -> sync(owners, "a", {1, 1}, idle_backends(1)) end)

      # The sync waits on the pool; the table does not.
      wait_until(fn -> :sys.get_state(owners).busy != nil end)
      assert Owners.boot(owners) == "bb_owners"
      assert {:error, :unknown_owner} = Owners.admit(owners, invoke("a", {1, 1}))
      assert :ok = Owners.sweep(owners)

      assert {:error, :unavailable} = Task.await(pending)
      assert :sys.get_state(owners).busy == nil
    end

    test "a replacing version counts the uids its predecessor is about to free", ctx do
      owners = start_owners(ctx)
      Agent.update(ctx.pool, fn _ -> pool(2) end)

      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_backends(2))
      assert {:ok, _} = sync(owners, "a", {1, 2}, idle_backends(2))

      # Until the first version's backends stop, the pool is full.
      assert {:error, :capacity} = sync(owners, "b", {1, 1}, idle_backends(1))
    end

    test "a retirement seen twice retires once, and frees each uid once", ctx do
      owners = start_owners(ctx)
      Agent.update(ctx.pool, fn _ -> pool(2) end)

      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_backends(2))
      release = %{type: :release, owners: [%{athanor: @athanor, server: "a", e: 1}]}

      assert {:ok, %{released: [%{server: "a", g: 1, e: 1}]}} = control(owners, 1, release)
      assert {:ok, %{released: []}} = control(owners, 1, release)
      assert {:ok, %{released: []}} = control(owners, 1, %{type: :reconcile, keep: []})
      assert {:error, :unknown_owner} = Owners.admit(owners, invoke("a", {1, 1}))

      # Retired, the owner holds its uids until its backends stop.
      assert {:error, :capacity} = sync(owners, "b", {1, 1}, idle_backends(1))
      wait_until(fn -> held(owners) == %{} end)

      # Then both uids are free, and no more than both.
      assert {:ok, _} = sync(owners, "b", {1, 1}, idle_backends(2))
      assert {:error, :capacity} = sync(owners, "c", {1, 1}, idle_backends(1))
      assert DynamicSupervisor.count_children(ctx.supervisor).active == 2
    end
  end

  describe "renew, release and reconcile" do
    test "renew extends an owner at exactly (g, e) with a live lease; every other is unknown",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {3, 1}, idle_backends(1), lease_ms: 1_000)
      assert {:ok, _} = sync(owners, "b", {3, 2}, idle_backends(1), lease_ms: 1_000)

      renew = fn g, entries ->
        control(owners, g, %{
          type: :renew,
          lease_ms: 5_000,
          owners: for({server, e} <- entries, do: %{athanor: @athanor, server: server, e: e})
        })
      end

      assert {:ok, %{renewed: [%{server: "a", e: 1, state: :starting, rev: 0}], unknown: unknown}} =
               renew.(3, [{"a", 1}, {"b", 1}, {"c", 1}])

      assert Enum.map(unknown, &{&1.server, &1.e}) == [{"b", 1}, {"c", 1}]

      # "a" was renewed for 5 s and "b" was not: past 1 s, "b" is lapsed.
      advance(ctx, 1_000)

      assert {:ok, %{renewed: [%{server: "a"}], unknown: [%{server: "b"}]}} =
               renew.(3, [{"a", 1}, {"b", 2}])

      # At another generation no owner is running.
      assert {:ok, %{renewed: [], unknown: [_]}} = renew.(4, [{"a", 1}])
    end

    test "release retires each owner at or below (g, e); reconcile each not at g and its kept e",
         ctx do
      owners = start_owners(ctx)
      Agent.update(ctx.pool, fn _ -> pool(8) end)

      assert {:ok, _} = sync(owners, "z", {2, 1}, idle_backends(1))
      assert {:ok, _} = sync(owners, "x", {3, 1}, idle_backends(1))
      assert {:ok, _} = sync(owners, "y", {3, 2}, idle_backends(1))
      assert {:ok, _} = sync(owners, "w", {3, 5}, idle_backends(1))

      entry = fn server, e -> %{athanor: @athanor, server: server, e: e} end

      # y at (3, 2) is above (3, 1); w at (3, 5) is at or below (3, 5).
      assert {:ok, %{released: released}} =
               control(owners, 3, %{type: :release, owners: [entry.("y", 1), entry.("w", 5)]})

      assert Enum.map(released, &{&1.server, &1.g, &1.e}) == [{"w", 3, 5}]

      # x is kept at (3, 1); y's kept epoch is another; z is another generation.
      assert {:ok, %{released: released}} =
               control(owners, 3, %{type: :reconcile, keep: [entry.("x", 1), entry.("y", 9)]})

      assert released |> Enum.map(&{&1.server, &1.g, &1.e}) |> Enum.sort() ==
               [{"y", 3, 2}, {"z", 2, 1}]

      assert {:ok, _} = Owners.admit(owners, invoke("x", {3, 1}))

      for {server, version} <- [{"y", {3, 2}}, {"z", {2, 1}}, {"w", {3, 5}}],
          do: assert({:error, :unknown_owner} = Owners.admit(owners, invoke(server, version)))
    end

    test "status reports each named owner present, a retired one absent", ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_backends(2), lease_ms: 10_000)
      advance(ctx, 2_500)

      status = %{
        type: :status,
        owners: [%{athanor: @athanor, server: "a"}, %{athanor: @athanor, server: "nope"}]
      }

      assert {:ok, %{owners: [owner]}} = control(owners, 1, status)

      assert %{server: "a", g: 1, e: 1, state: :starting, rev: 0, lease_ms_left: 7_500} =
               owner

      assert [%{name: "b1", error: nil, restarts: 0}, %{name: "b2"}] = owner.backends
      assert Enum.all?(owner.backends, &(&1.status in [:spawning, :initializing]))
      assert {:ok, _body} = Prima.LocusBackends.encode_answer(:status, %{owners: [owner]})
    end
  end

  describe "leases and idleness, through a driven sweep" do
    test "a lease that passes lapses the owner: lapsed while it retires, then gone", ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_backends(1), lease_ms: 1_000)

      advance(ctx, 999)
      :ok = LeaseSweeper.sweep(owners)
      assert {:ok, _} = Owners.admit(owners, invoke("a", {1, 1}))

      advance(ctx, 1)
      :ok = LeaseSweeper.sweep(owners)
      assert {:error, :lapsed} = Owners.admit(owners, invoke("a", {1, 1}))

      status = %{type: :status, owners: [%{athanor: @athanor, server: "a"}]}

      assert {:ok, %{owners: [%{state: :draining, lease_ms_left: 0}]}} =
               control(owners, 1, status)

      wait_until(fn -> Owners.admit(owners, invoke("a", {1, 1})) == {:error, :unknown_owner} end)
      assert DynamicSupervisor.count_children(ctx.supervisor).active == 0
    end

    test "an invoke past the lease lapses the owner without waiting for the sweep", ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_backends(1), lease_ms: 1_000)
      advance(ctx, 1_000)
      assert {:error, :lapsed} = Owners.admit(owners, invoke("a", {1, 1}))
      assert [%{state: :draining}] = Map.values(held(owners))
    end

    @tag :requires_node
    test "a ready backend unused for the idle period retires, frees its uid, and wakes for a call",
         ctx do
      owners = start_owners(ctx)
      Agent.update(ctx.pool, fn _ -> pool(1) end)
      probe = [{"probe", probe(), %{"PROBE_TOKEN" => "tok-0123456789abcdef"}}]

      assert {:ok, _} = sync(owners, "a", {1, 1}, probe, idle_ms: 1_000)
      pid = backend_pid(owners, "a", {1, 1}, "probe")
      wait_until(fn -> Backend.status(pid).status == :ready end)

      # Used within the period: kept.
      advance(ctx, 999)
      :ok = LeaseSweeper.sweep(owners)
      assert %{status: :ready} = Backend.status(pid)

      advance(ctx, 1)
      :ok = LeaseSweeper.sweep(owners)
      wait_until(fn -> Backend.status(pid).status == :idle end)
      assert %{tools: 2} = Backend.status(pid)

      # Its uid is free once its process is retired: another owner takes it.
      [owner] = Map.values(held(owners))
      wait_until(fn -> not held(owners)[owner.id].backends["probe"].slot end)
      assert {:ok, _} = sync(owners, "b", {1, 1}, [{"other", @idle, %{}}])

      # With no uid free, the call cannot wake it.
      assert {:error, {:tool_error, text}} = Backend.call_tool(pid, "echo", %{})
      assert text == "backend 'probe' is idle and no uid of the pool is free to start it"

      # Once one is, the call wakes it and is answered.
      release = %{type: :release, owners: [%{athanor: @athanor, server: "b", e: 1}]}
      assert {:ok, _} = control(owners, 1, release)
      wait_until(fn -> map_size(held(owners)) == 1 end)

      assert {:ok, %{"content" => [%{"text" => ~s({"said":"again"})}]}} =
               Backend.call_tool(pid, "echo", %{"said" => "again"})

      assert %{status: :ready} = Backend.status(pid)
      assert held(owners)[owner.id].backends["probe"].slot
    end
  end

  describe "readiness and calls" do
    @tag :requires_node
    test "a sync is answered on admission, and rev says when its backends are ready", ctx do
      owners = start_owners(ctx)
      probe = [{"probe", probe(), %{"PROBE_TOKEN" => "tok-0123456789abcdef"}}]

      assert {:ok,
              %{
                status: :starting,
                rev: 0,
                backends: [%{name: "probe", status: :spawning, tools: 0}]
              }} =
               sync(owners, "a", {1, 1}, probe)

      renew = %{type: :renew, lease_ms: 30_000, owners: [%{athanor: @athanor, server: "a", e: 1}]}

      # Ready with its tools listed (the catalogue changed), then running.
      wait_until(fn ->
        match?({:ok, %{renewed: [%{state: :running}]}}, control(owners, 1, renew))
      end)

      assert {:ok, %{renewed: [%{state: :running, rev: 2}]}} = control(owners, 1, renew)

      status = %{type: :status, owners: [%{athanor: @athanor, server: "a"}]}

      assert {:ok, %{owners: [%{state: :running, rev: 2, backends: [backend]}]}} =
               control(owners, 1, status)

      assert %{name: "probe", status: :ready, tools: 2, restarts: 0, error: nil} = backend
      assert backend.stderr_tail =~ "probe started"

      # An equal sync answers the backends as they are.
      assert {:ok, %{status: :running, rev: 2, backends: [%{status: :ready, tools: 2}]}} =
               sync(owners, "a", {1, 1}, probe)
    end

    @tag :requires_node
    test "a crash withdraws the tools and raises rev; the status names the crash", ctx do
      owners =
        start_owners(ctx,
          backend_opts: [
            launcher: Locus.DirectLauncher,
            launcher_server: [],
            bounds: [restart_backoff_ms: [60_000]],
            release_timeout_ms: 5_000
          ]
        )

      probe = [{"probe", probe(), %{}}]
      assert {:ok, _} = sync(owners, "a", {1, 1}, probe)
      pid = backend_pid(owners, "a", {1, 1}, "probe")
      wait_until(fn -> Backend.status(pid).status == :ready end)

      assert {:error, {:tool_error, _}} = Backend.call_tool(pid, "crash", %{})
      status = %{type: :status, owners: [%{athanor: @athanor, server: "a"}]}

      wait_until(fn ->
        match?({:ok, %{owners: [%{rev: 3}]}}, control(owners, 1, status))
      end)

      assert {:ok, %{owners: [%{backends: [backend]}]}} = control(owners, 1, status)
      assert %{status: :crashed, tools: 0} = backend
      assert backend.error =~ "exited code=3"
    end

    @tag :requires_node
    test "the calls awaiting one backend are bounded by the configured in-flight bound", ctx do
      owners = start_owners(ctx, max_in_flight: 1)
      probe = [{"probe", probe(), %{}}]
      assert {:ok, _} = sync(owners, "a", {1, 1}, probe)
      pid = backend_pid(owners, "a", {1, 1}, "probe")
      wait_until(fn -> Backend.status(pid).status == :ready end)

      # A line that is no answer: the call awaits one until it is stopped.
      waiting = Task.async(fn -> Backend.call_tool(pid, "flood", %{"bytes" => 8}) end)

      wait_until(fn ->
        Locus.Backends.Relay.pending_count(:sys.get_state(pid).relay) == 1
      end)

      assert {:error, {:tool_error, "backend busy: 1 calls in flight"}} =
               Backend.call_tool(pid, "echo", %{})

      release = %{type: :release, owners: [%{athanor: @athanor, server: "a", e: 1}]}
      assert {:ok, _} = control(owners, 1, release)
      assert {:error, {:tool_error, _stopped}} = Task.await(waiting)
    end
  end
end
