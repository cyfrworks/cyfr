# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.StartupAdmissionBarrierTest do
  @moduledoc """
  Startup order is the admission barrier: the gate — the declared
  restore's step, then the storage reserve (`Cyfr.StorageReserve`) — sits
  between the children a declared restore's transition needs and every
  child that admits work, and only the step's checked success lets the
  rest of the tree — and the endpoint after it — start.

  The census is read from `Cyfr.Application.tiers/0`, the tree the boot
  starts down through every subtree, and pinned exactly: a child added
  before the gate, or moved across it or between subtrees, fails here
  until someone decides where it belongs.

  The barrier is exercised on that same list under a supervisor of the
  test's own. The step runs the product's own
  (`Cyfr.Application.declared_restore/0`) against the database, in the
  tier's process as the product runs it, paused behind a barrier the test
  lifts; every other child is a stand-in that records being started and
  stopped, under supervisors built with the product's strategies and
  intensities, because the running suite's own tree already holds those
  names. With a due schedule, an open turn, an enabled backend, a
  person's session and a declared restore's marker in the database,
  nothing after the gate starts, nothing is dispensed and nothing is
  published until the transition has committed — and when the step
  refuses (a lost slot, a member holding no slot, a tier killed
  mid-step), nothing after it ever does, and the marker stays for the
  next start.

  The same holds after boot. A stand-in killed before the gate restarts
  everything after it, the gate first; one killed after the gate restarts
  only what follows it; a refused rerun fails the tier and then the root;
  an endpoint in a crash loop exhausts the web tier alone; and a dead
  backends controller restarts the servers that release through it.

  A stop is the start backwards: the endpoint first, the cell last, and
  every child that holds a claim stopped before its tier returns.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  # Every switch that can add a child, on — the census is the full tree a
  # clustered, database-checked production boot starts.
  @flags [
    {:cyfr, :provisioning_boot_enabled, true},
    {:cyfr, :database_checks_enabled, true},
    {:cyfr, :thread_recovery, true},
    {:arca, :control_plane_claim_enabled, true},
    {:libcluster, :topologies, [cyfr: [strategy: Cluster.Strategy.Epmd, config: [hosts: []]]]}
  ]

  @pre_gate [
    Cyfr.KeyringFingerprint.Check,
    Cluster.Supervisor,
    Cyfr.Cell,
    Arca.AuditHandler,
    CyfrWeb.Telemetry,
    Phoenix.PubSub.Supervisor,
    Cyfr.StandingWatch,
    Cyfr.TelemetryBridge,
    Cyfr.Platform.Settings
  ]

  # The gate: the declared restore's step, then the storage reserve, which
  # derives its latch before anything admits work.
  @gate [:declared_restore, Cyfr.StorageReserve]

  # A supervisor the census describes is `{id, children}`, in start order.
  @post_gate [
    Cyfr.RetentionScheduler,
    CyfrWeb.SSE.Registry,
    {Sanctum.Gate.Supervisor, [Sanctum.RunningTasks, Sanctum.Gate.TaskSupervisor]},
    {Compendium.Supervisor,
     [
       Compendium.Builds.TaskSupervisor,
       Compendium.ProvisioningSupervisor,
       Compendium.ProjectionReconciler
     ]},
    {Opus.Supervisor,
     [
       Opus.Slots,
       {Opus.Tree,
        [
          Opus.Registry,
          Opus.Events.Registry,
          Opus.Events.Sequence,
          Opus.Events.Supervisor,
          Opus.Attempt.Registry,
          Opus.Attempt.Supervisor
        ]},
       Opus.TaskSupervisor,
       Opus.ArchiveWatch,
       Opus.Sweeper,
       Opus.WorkerWatch,
       Opus.Host.Egress.Pins,
       Opus.HostListener
     ]},
    {Aqua.Supervisor,
     [
       Aqua.ScheduleNotes,
       {Aqua.WorkerTree, [Aqua.Loop.Worker, Aqua.TaskSupervisor]},
       {Aqua.RunnerTree, [Aqua.RunnerRegistry, Aqua.RunnerSupervisor, Aqua.RunnerRecovery]}
     ]},
    {Emissary.Supervisor,
     [
       {Emissary.External.ServerTree,
        [
          Emissary.External.ServerRegistry,
          Emissary.External.Backends,
          Emissary.External.ServerSupervisor,
          Emissary.External.Reconciler
        ]},
       Emissary.TaskSupervisor
     ]},
    Opus.Schedules.TaskSupervisor,
    Opus.Schedules.Scheduler,
    Prism.TinctureRegistry,
    Prism.TaskSupervisor,
    Cyfr.SeedOffer
  ]

  # Every supervisor the census describes, with its strategy and its
  # restart intensity.
  @supervisors %{
    Cyfr.InfraSupervisor => {:rest_for_one, {10, 60}},
    Cyfr.WebSupervisor => {:one_for_one, {10, 60}},
    Sanctum.Gate.Supervisor => {:rest_for_one, {10, 60}},
    Compendium.Supervisor => {:one_for_one, {10, 60}},
    Opus.Supervisor => {:rest_for_one, {10, 60}},
    Opus.Tree => {:rest_for_one, {10, 60}},
    Aqua.Supervisor => {:rest_for_one, {10, 60}},
    Aqua.WorkerTree => {:rest_for_one, {10, 60}},
    Aqua.RunnerTree => {:rest_for_one, {10, 60}},
    Emissary.Supervisor => {:one_for_one, {10, 60}},
    Emissary.External.ServerTree => {:rest_for_one, {10, 60}}
  }

  @web [Emissary.Web.TaskSupervisor, CyfrWeb.Endpoint]

  # The order a stop of the whole tree stops every lasting child in: the
  # web tier, the seed offer, the console, the schedule pair, then the
  # domains in reverse (the host API listener before the attempt tree it
  # reaches), and the foundations down to the cell.
  @stop_order [
    CyfrWeb.Endpoint,
    Emissary.Web.TaskSupervisor,
    Cyfr.SeedOffer,
    Prism.TaskSupervisor,
    Prism.TinctureRegistry,
    Opus.Schedules.Scheduler,
    Opus.Schedules.TaskSupervisor,
    Emissary.TaskSupervisor,
    Emissary.External.Reconciler,
    Emissary.External.ServerSupervisor,
    Emissary.External.Backends,
    Emissary.External.ServerRegistry,
    Aqua.RunnerSupervisor,
    Aqua.RunnerRegistry,
    Aqua.TaskSupervisor,
    Aqua.Loop.Worker,
    Aqua.ScheduleNotes,
    Opus.HostListener,
    Opus.Host.Egress.Pins,
    Opus.WorkerWatch,
    Opus.Sweeper,
    Opus.ArchiveWatch,
    Opus.TaskSupervisor,
    Opus.Attempt.Supervisor,
    Opus.Attempt.Registry,
    Opus.Events.Supervisor,
    Opus.Events.Sequence,
    Opus.Events.Registry,
    Opus.Registry,
    Opus.Slots,
    Compendium.ProjectionReconciler,
    Compendium.ProvisioningSupervisor,
    Compendium.Builds.TaskSupervisor,
    Sanctum.Gate.TaskSupervisor,
    Sanctum.RunningTasks,
    CyfrWeb.SSE.Registry,
    Cyfr.RetentionScheduler,
    Cyfr.StorageReserve,
    Cyfr.Platform.Settings,
    Cyfr.TelemetryBridge,
    Cyfr.StandingWatch,
    Phoenix.PubSub.Supervisor,
    CyfrWeb.Telemetry,
    Arca.AuditHandler,
    Cyfr.Cell,
    Cluster.Supervisor
  ]

  # The children that hold a claim or a slot row while they run.
  @claim_holders [
    Cyfr.SeedOffer,
    Cyfr.Cell,
    Cyfr.RetentionScheduler,
    Opus.WorkerWatch,
    Emissary.External.Backends
  ]

  # The leaves the product starts no lasting process for: the one-shot
  # checks and the declared restore's step answer `:ignore`, and the
  # recovery task exits once it has run.
  # Their stand-ins leave no process either. The seed
  # offer is not among them: it runs after its start has returned, holding
  # its claim until it ends or is stopped.
  @no_process [
    Cyfr.KeyringFingerprint.Check,
    :declared_restore,
    Aqua.RunnerRecovery
  ]

  # The children a rest_for_one restart from `Cyfr.Cell` starts before the
  # declared restore's step, in order.
  @from_cell Enum.drop_while(@pre_gate, &(&1 != Cyfr.Cell))

  @credential_events [
    [:cyfr, :sanctum, :provider_credentials, :fetch],
    [:cyfr, :sanctum, :vault, :oauth_refresh],
    [:cyfr, :opus, :oauth, :token_request],
    [:cyfr, :opus, :secret, :dispensed]
  ]

  @control_plane_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    saved_env = for {app, key, _} <- @flags, do: {app, key, Application.fetch_env(app, key)}
    saved_terms = Map.new(@control_plane_keys, &{&1, :persistent_term.get(&1, :absent)})

    on_exit(fn ->
      for {app, key, saved} <- saved_env do
        case saved do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end

      for {key, value} <- saved_terms do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end
    end)

    for {app, key, value} <- @flags, do: Application.put_env(app, key, value)

    :ok
  end

  describe "the census" do
    test "only the declared restore's needs start before the gate; everything that admits work after it" do
      tiers = Cyfr.Application.tiers()

      [{Cyfr.InfraSupervisor, _, _, infra}, {Cyfr.WebSupervisor, _, _, web}] = tiers
      ids = Enum.map(infra, &shape/1)

      {pre, post} = Enum.split_while(ids, &(&1 != :declared_restore))

      assert pre == @pre_gate
      assert post == @gate ++ @post_gate
      assert Enum.map(web, &shape/1) == @web
      assert Map.new(Enum.flat_map(tiers, &strategies/1)) == @supervisors

      # The declared restore's step is transient: it answers once and
      # leaves no process, stays listed, and runs again on every restart of
      # what precedes it, finding no marker; a refusal it returns is the
      # supervisor's failure to start. The reserve stops within its bound.
      # The offer is temporary: it runs once, at boot.
      assert %{restart: :transient, start: {Cyfr.Application, :declared_restore, []}} =
               infra |> Enum.find(&(shape(&1) == :declared_restore)) |> spec()

      assert %{shutdown: 5_000} =
               infra |> Enum.find(&(shape(&1) == Cyfr.StorageReserve)) |> spec()

      assert %{restart: :temporary} = infra |> Enum.find(&(shape(&1) == Cyfr.SeedOffer)) |> spec()

      # The cell, which the suite's own boot omits, releases its slot row
      # within its stated bound.
      assert %{shutdown: 5_000} = infra |> Enum.find(&(shape(&1) == Cyfr.Cell)) |> spec()
    end

    test "only a test build with boot work switched off omits the gate" do
      refute Cyfr.Application.bootstrap_skipped?(false, false)
      refute Cyfr.Application.bootstrap_skipped?(false, true)
      refute Cyfr.Application.bootstrap_skipped?(true, true)
      assert Cyfr.Application.bootstrap_skipped?(true, false)

      Application.put_env(:cyfr, :provisioning_boot_enabled, false)
      [{_, _, _, infra}, _web] = Cyfr.Application.tiers()
      ids = Enum.map(infra, &shape/1)
      refute :declared_restore in ids
      refute Cyfr.StorageReserve in ids
      refute Cyfr.SeedOffer in ids
    end

    test "the permission to omit it is the suite's configuration and no other's" do
      root = Path.expand("../../../..", __DIR__)

      setting =
        for path <-
              Path.wildcard(Path.join(root, "config/*.exs")) ++
                Path.wildcard(Path.join(root, "apps/*/config/*.exs")),
            File.read!(path) =~ ~r/^config :cyfr,.*bootstrap_skip_permitted/m,
            do: Path.relative_to(path, root)

      assert setting == ["config/test.exs"]
    end
  end

  describe "the barrier" do
    setup do
      slot = hold_slot!()
      rows = admitting_rows!()
      restored = declared_restore!()

      test = self()
      handler = "barrier-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        @credential_events,
        fn event, _m, _meta, _c -> send(test, {:credential, event}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      for topic <- rows.topics, do: :ok = Cyfr.Bus.subscribe(rows.actor, topic)

      {:ok, slot: slot, rows: rows, restored: restored}
    end

    test "nothing that admits work starts, is dispensed or is published until the gate returns",
         %{rows: rows, restored: restored} do
      starter = start_tree!()
      assert_receive {:paused, gate}, 5_000

      assert started() == @pre_gate
      refute_receive {:started, _}, 300
      refute_receive {:credential, _}
      refute_receive {:tree, _, _}
      untouched!(rows)

      assert restore_state(restored) == %{marker: true, session: true},
             "the transition committed before its barrier lifted"

      send(gate, {:lift, real(self())})
      assert_receive {:answered, :ignore}, 10_000

      assert_receive {:tree, ^starter, {:ok, _root}}, 10_000
      # The reserve derives its latch before anything that admits work,
      # and the endpoint is last: it starts only after the gate returned
      # and every child that admits work is up.
      assert started() == [Cyfr.StorageReserve | leaves(@post_gate)] ++ @web

      assert restore_state(restored) == %{marker: false, session: false}
      refute_receive {:credential, _}
      stop_tree(starter)
    end

    test "a lost slot or a member holding none refuses the boot, keeps the marker, and nothing after starts",
         %{slot: slot, restored: restored} do
      refusals = [
        slot_lost: fn -> expire_slot!(slot) end,
        slot_not_held: fn -> Arca.ControlPlane.record(:lost) end
      ]

      for {class, lose} <- refusals do
        starter = start_tree!()
        assert_receive {:paused, gate}, 5_000
        assert started() == @pre_gate
        refute_receive {:started, _}, 200

        lose.()
        send(gate, {:lift, real(self())})
        assert_receive {:answered, {:error, {:restore_refused, ^class}}}, 10_000
        assert_receive {:tree, ^starter, {:error, reason}}, 10_000
        assert refused(reason) == class
        refute_receive {:started, _}, 100
        refute_receive {:credential, _}
        stop_tree(starter)

        # The transition rolled back whole: the next boot finds the marker.
        assert restore_state(restored) == %{marker: true, session: true}
      end
    end

    test "a tier killed mid-step starts nothing, and the next start runs the step first",
         %{restored: restored} do
      starter = start_tree!()
      assert_receive {:paused, gate}, 5_000
      assert started() == @pre_gate

      Process.exit(gate, :kill)
      assert_receive {:tree, ^starter, {:error, _reason}}, 10_000
      refute_receive {:started, _}, 200
      assert restore_state(restored) == %{marker: true, session: true}
      stop_tree(starter)

      # The restarted tree runs the step again from the start, and finds
      # the marker its dead predecessor left.
      starter = start_tree!()
      assert_receive {:paused, gate}, 5_000
      assert started() == @pre_gate
      refute_receive {:started, _}, 200

      send(gate, {:lift, real(self())})
      assert_receive {:answered, :ignore}, 10_000
      assert_receive {:tree, ^starter, {:ok, _root}}, 10_000
      assert started() == [Cyfr.StorageReserve | leaves(@post_gate)] ++ @web
      assert restore_state(restored) == %{marker: false, session: false}
      stop_tree(starter)
    end
  end

  describe "a restart after boot" do
    setup do
      slot = hold_slot!()
      rows = admitting_rows!()
      {:ok, slot: slot, rows: rows}
    end

    @tag :capture_log
    test "an endpoint crash loop restarts the web tier alone, and no healthy domain" do
      {starter, root} = booted!()
      web = pid_at(root, [:barrier_web])
      web_ref = Process.monitor(web)

      # Ten restarts are within the web tier's intensity; the eleventh
      # exhausts it, and the root starts the tier again.
      for _ <- 1..10 do
        kill!(root, [:barrier_web, CyfrWeb.Endpoint])
        next_started!([CyfrWeb.Endpoint])
      end

      kill!(root, [:barrier_web, CyfrWeb.Endpoint])
      assert_receive {:DOWN, ^web_ref, :process, ^web, :shutdown}, 5_000
      next_started!(@web)
      quiet!()
      refute pid_at(root, [:barrier_web]) == web
      refute_received {:paused, _}
      stop_tree(starter)
    end

    @tag :capture_log
    test "a restarted infra tier serves the operation table this boot built" do
      operations = Sanctum.Catalog.operations()
      {starter, root} = booted!()

      kill!(root, [:barrier_infra, Cyfr.Cell])
      next_started!(@from_cell)
      assert_receive {:paused, gate}, 5_000
      send(gate, {:lift, real(self())})
      assert_receive {:answered, :ignore}, 5_000
      next_started!([Cyfr.StorageReserve | restarting(@post_gate)])

      assert Sanctum.Catalog.operations() === operations
      assert :persistent_term.get({Sanctum.Gate, :operations}) === operations
      stop_tree(starter)
    end

    test "the operation table and its index are written by the catalog's load alone" do
      root = Path.expand("../../../..", __DIR__)

      # The host's tree and Sanctum's, which holds the gate.
      sources =
        for lib <- ~w(apps/cyfr/lib apps/sanctum/lib),
            path <- Path.wildcard(Path.join([root, lib, "**/*.ex"])),
            into: %{},
            do: {Path.relative_to(path, root), File.read!(path)}

      writers = for {path, source} <- sources, gate_term_put?(source), do: path

      assert Enum.sort(writers) == [
               "apps/sanctum/lib/sanctum/catalog.ex",
               "apps/sanctum/lib/sanctum/resources.ex"
             ]

      # The index's writer is a helper, and the catalog is its one caller.
      callers = for {path, source} <- sources, source =~ ~r/Resources\.put[(\/]/, do: path
      assert callers == ["apps/sanctum/lib/sanctum/catalog.ex"]
    end

    @tag :capture_log
    test "a partial infra restart reruns the gate before anything that admits work", %{
      slot: slot,
      rows: rows
    } do
      {starter, root} = booted!()
      infra = pid_at(root, [:barrier_infra])

      # From the cell down: nothing before it restarts, the step reruns
      # before anything after it — in the tier's own process — and while
      # it is paused nothing acts.
      kill!(root, [:barrier_infra, Cyfr.Cell])
      next_started!(@from_cell)
      assert_receive {:paused, ^infra}, 5_000
      quiet!()
      untouched!(rows)

      send(infra, {:lift, real(self())})
      assert_receive {:answered, :ignore}, 5_000
      next_started!([Cyfr.StorageReserve | restarting(@post_gate)])
      quiet!()

      # The step is the product's transient child: once its rerun has
      # answered it stays listed, with no process, for the next cascade.
      assert {:ok, %{restart: :transient}} = :supervisor.get_childspec(infra, :declared_restore)

      assert {:declared_restore, :undefined, :worker, _} =
               infra |> Supervisor.which_children() |> List.keyfind(:declared_restore, 0)

      # From a domain after the gate: only what follows it restarts, and
      # the gate does not run.
      kill!(root, [:barrier_infra, Compendium.Supervisor])

      next_started!(
        restarting(Enum.drop_while(@post_gate, &(id_of(&1) != Compendium.Supervisor)))
      )

      quiet!()
      refute_received {:paused, _}

      # A rerun that keeps refusing — the slot lapsed — fails the tier,
      # whose restart by the root runs the step in the tier's own start and
      # fails it again, until the root gives up too.
      expire_slot!(slot)
      infra_ref = Process.monitor(infra)
      kill!(root, [:barrier_infra, Cyfr.Cell])
      next_started!(@from_cell)

      {reason, tiers} = refuse_until_root_exits(starter)
      assert reason == :shutdown
      assert_received {:DOWN, ^infra_ref, :process, ^infra, :shutdown}
      assert infra in tiers
      assert Enum.any?(tiers, &(&1 != infra)), "the root never restarted the infra tier"
      assert_received {:stopped, CyfrWeb.Endpoint}
      assert Enum.all?(started(), &(&1 in @pre_gate)), "a child after the gate started"
      stop_tree(starter)
    end

    @tag :capture_log
    test "a rerun under a lapsed slot refuses, and a cascade keeps this boot's id", %{
      slot: slot
    } do
      boot = Prima.Boot.id()
      {starter, root} = booted!()

      kill!(root, [:barrier_infra, Cyfr.Cell])
      next_started!(@from_cell)
      assert_receive {:paused, gate}, 5_000
      send(gate, {:lift, real(self())})
      assert_receive {:answered, :ignore}, 5_000
      next_started!([Cyfr.StorageReserve | restarting(@post_gate)])
      assert Prima.Boot.id() == boot

      expire_slot!(slot)
      kill!(root, [:barrier_infra, Cyfr.Cell])
      next_started!(@from_cell)
      assert_receive {:paused, gate}, 5_000
      send(gate, {:lift, real(self())})
      assert_receive {:answered, {:error, {:restore_refused, :slot_lost}}}, 5_000

      # The tier tries the step again; nothing after it starts meanwhile.
      assert_receive {:paused, retry}, 5_000
      quiet!()
      stop_tree(starter, [retry])
    end

    # The servers release their owners through the controller, so a
    # controller that dies takes them down and starts them again after
    # it, with the reconciler that fills them; the registry before it,
    # and everything outside the group, keep running.
    @tag :capture_log
    test "a dead backends controller restarts the servers it releases, and nothing else" do
      {starter, root} = booted!()
      group = [:barrier_infra, Emissary.Supervisor, Emissary.External.ServerTree]
      registry = pid_at(root, group ++ [Emissary.External.ServerRegistry])

      kill!(root, group ++ [Emissary.External.Backends])
      next_stopped!([Emissary.External.Reconciler, Emissary.External.ServerSupervisor])

      next_started!([
        Emissary.External.Backends,
        Emissary.External.ServerSupervisor,
        Emissary.External.Reconciler
      ])

      quiet!()
      refute_received {:stopped, _}
      assert pid_at(root, group ++ [Emissary.External.ServerRegistry]) == registry
      stop_tree(starter)
    end
  end

  describe "a stop" do
    setup do
      {:ok, slot: hold_slot!()}
    end

    test "runs the start backwards, and every claim holder is down before its tier returns" do
      {starter, root} = booted!()
      infra = pid_at(root, [:barrier_infra])

      # The step answered and left no process: nothing of it is left to
      # stop.
      assert {:declared_restore, :undefined, :worker, _} =
               infra |> Supervisor.which_children() |> List.keyfind(:declared_restore, 0)

      infra_ref = Process.monitor(infra)
      :ok = Supervisor.stop(root)
      stops = stops(infra_ref)

      assert stops -- [:infra_down] == @stop_order

      assert @stop_order ==
               Enum.reverse(@pre_gate ++ @gate ++ leaves(@post_gate) ++ @web) -- @no_process

      # The tier's own exit is the last thing a stop of the tree sees.
      assert List.last(stops) == :infra_down
      down = Enum.find_index(stops, &(&1 == :infra_down))

      for holder <- @claim_holders do
        assert Enum.find_index(stops, &(&1 == holder)) < down,
               "#{inspect(holder)} did not stop before its tier returned"
      end

      stop_tree(starter)
    end
  end

  # ---------------------------------------------------------------------------
  # The tree, with stand-ins for every child but the declared restore's step
  # ---------------------------------------------------------------------------

  defmodule StandIn do
    @moduledoc false
    # A leaf's stand-in: a process that records its start and its stop, and
    # stops abnormally when told to crash.

    use GenServer

    def start_link(id, test), do: GenServer.start_link(__MODULE__, {id, test})

    @impl true
    def init({id, test}) do
      Process.flag(:trap_exit, true)
      send(test, {:started, id})
      {:ok, {id, test}}
    end

    @impl true
    def handle_info(:crash, state), do: {:stop, :crashed, state}

    @impl true
    def terminate(_reason, {id, test}), do: send(test, {:stopped, id})
  end

  @doc false
  # The stand-in of a leaf that leaves no process: records that the
  # supervisor started it, and answers `:ignore`.
  def probe(id, test) do
    send(test, {:started, id})
    :ignore
  end

  @doc false
  # The declared restore's step as the tier starts it, in the tier's own
  # process: it says it is paused and runs the work the test hands it — the
  # product's step (`real/1`) — answering what that answers.
  def paused_step(test) do
    send(test, {:paused, self()})

    receive do
      {:lift, work} -> work.()
    end
  end

  # The tiers under a root with the product root's strategy and intensity
  # (`Cyfr.Supervisor`), and under ids of the test's own, so a refusal
  # names them. The starter reports the root's exit and stops the tree
  # when told to.
  defp start_tree! do
    test = self()
    [infra, web] = Cyfr.Application.tiers()

    root = [
      %{stand_in(infra, test) | id: :barrier_infra},
      %{stand_in(web, test) | id: :barrier_web}
    ]

    spawn(fn ->
      Process.flag(:trap_exit, true)

      result =
        Supervisor.start_link(root, strategy: :rest_for_one, max_restarts: 10, max_seconds: 60)

      send(test, {:tree, self(), result})
      hold(test, result)
    end)
  end

  defp hold(test, result) do
    receive do
      :stop ->
        with {:ok, root} <- result do
          try do
            Supervisor.stop(root)
          catch
            :exit, _gone -> :ok
          end
        end

      {:EXIT, pid, reason} ->
        if match?({:ok, ^pid}, result), do: send(test, {:tree_exit, self(), reason})
        hold(test, result)
    end
  end

  # A step paused while the tree stops would hold its tier for good: the
  # paused tiers the test holds, and any the root starts meanwhile, are
  # killed.
  defp stop_tree(starter, gates \\ []) do
    ref = Process.monitor(starter)
    send(starter, :stop)
    Enum.each(gates, &Process.exit(&1, :kill))
    await_stopped(starter, ref)
  end

  defp await_stopped(starter, ref) do
    receive do
      {:DOWN, ^ref, :process, ^starter, _} ->
        :ok

      {:paused, gate} ->
        Process.exit(gate, :kill)
        await_stopped(starter, ref)
    after
      10_000 -> flunk("the tree did not stop")
    end
  end

  # A tree whose step ran the product's (no restore declared), with every
  # start drained.
  defp booted! do
    starter = start_tree!()
    assert_receive {:paused, gate}, 5_000
    send(gate, {:lift, real(self())})
    assert_receive {:answered, :ignore}, 5_000
    assert_receive {:tree, ^starter, {:ok, root}}, 10_000
    assert started() == @pre_gate ++ [Cyfr.StorageReserve | leaves(@post_gate)] ++ @web
    {starter, root}
  end

  # The running child at `path`, a list of child ids from `supervisor`.
  defp pid_at(supervisor, []), do: supervisor

  defp pid_at(supervisor, [id | path]) do
    {^id, pid, _type, _modules} =
      supervisor |> Supervisor.which_children() |> List.keyfind(id, 0)

    pid_at(pid, path)
  end

  # Kills a child: a stand-in crashes and is awaited through its own
  # stop, a supervisor is killed and awaited through its monitor.
  defp kill!(root, path) do
    id = List.last(path)
    pid = pid_at(root, path)
    ref = Process.monitor(pid)

    if Map.has_key?(@supervisors, id) do
      Process.exit(pid, :kill)
    else
      send(pid, :crash)
      assert_receive {:stopped, ^id}, 5_000
    end

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
  end

  # The next stand-ins to start are `ids`, in this order.
  defp next_started!(ids) do
    for id <- ids do
      assert_receive {:started, started}, 5_000
      assert started == id
    end
  end

  # The next stand-ins to stop are `ids`, in this order.
  defp next_stopped!(ids) do
    for id <- ids do
      assert_receive {:stopped, stopped}, 5_000
      assert stopped == id
    end
  end

  defp quiet!, do: refute_receive({:started, _}, 200)

  # Every stand-in stopped so far, in the order they stopped, with
  # `:infra_down` where the monitored tier's exit arrived among them.
  defp stops(infra_ref, acc \\ []) do
    receive do
      {:stopped, id} -> stops(infra_ref, [id | acc])
      {:DOWN, ^infra_ref, :process, _pid, _reason} -> stops(infra_ref, [:infra_down | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  # The leaves of `shapes` a restart starts again: all but the offer,
  # which is temporary and runs once, at boot.
  defp restarting(shapes), do: leaves(shapes) -- [Cyfr.SeedOffer]

  defp id_of({id, _children}), do: id
  defp id_of(id), do: id

  # Whether `source` writes a `:persistent_term` key `{Sanctum.Gate, _}`, given
  # literally or through a module attribute bound to one. The key is read up
  # to its first comma, so a literal one is matched by the tuple's first
  # element.
  defp gate_term_put?(source) do
    attributes =
      for [name] <- Regex.scan(~r/@(\w+)\s+\{Sanctum.Gate,/, source, capture: :all_but_first),
          do: "@" <> name

    source
    |> then(&Regex.scan(~r/:persistent_term\.put\(\s*([^,]+),/, &1, capture: :all_but_first))
    |> Enum.any?(fn [key] ->
      key = String.trim(key)
      key =~ ~r/^\{\s*Sanctum\.Gate$/ or key in attributes
    end)
  end

  # Lifts every rerun with the product's step, which refuses, until the
  # root gives up, answering the root's exit reason and the tier each
  # rerun ran in, in order.
  defp refuse_until_root_exits(starter, tiers \\ []) do
    receive do
      {:paused, tier} ->
        send(tier, {:lift, real(self())})
        assert_receive {:answered, {:error, {:restore_refused, _class}}}, 5_000
        refuse_until_root_exits(starter, [tier | tiers])

      {:tree_exit, ^starter, reason} ->
        {reason, Enum.reverse(tiers)}
    after
      10_000 -> flunk("the root did not give up")
    end
  end

  # A supervisor the census describes is built, unnamed, with the
  # product's strategy and intensity over its children's stand-ins.
  defp stand_in({id, strategy, {max_restarts, max_seconds}, children}, test) do
    %{
      id: id,
      start:
        {Supervisor, :start_link,
         [
           Enum.map(children, &stand_in(&1, test)),
           [strategy: strategy, max_restarts: max_restarts, max_seconds: max_seconds]
         ]},
      type: :supervisor
    }
  end

  # A leaf keeps the product's id, restart and shutdown: the declared
  # restore's step is the paused product step, a leaf the product leaves
  # no process for is the probe, and every other leaf is a live stand-in.
  defp stand_in(child, test) do
    spec = child |> spec() |> Map.take([:id, :restart, :shutdown, :type])

    start =
      case spec.id do
        :declared_restore -> {__MODULE__, :paused_step, [test]}
        id when id in @no_process -> {__MODULE__, :probe, [id, test]}
        id -> {StandIn, :start_link, [id, test]}
      end

    Map.put(spec, :start, start)
  end

  defp spec(child), do: Supervisor.child_spec(child, [])
  defp id(child), do: spec(child).id

  # A child's place in the census: its id, or a supervisor's id and its
  # children's places.
  defp shape({id, _strategy, _intensity, children}), do: {id, Enum.map(children, &shape/1)}
  defp shape(child), do: id(child)

  defp strategies({id, strategy, intensity, children}),
    do: [{id, {strategy, intensity}} | Enum.flat_map(children, &strategies/1)]

  defp strategies(_child), do: []

  # The children a shape starts, in start order.
  defp leaves(shapes),
    do:
      Enum.flat_map(shapes, fn
        {_id, children} -> leaves(children)
        id -> [id]
      end)

  # Every stand-in started so far, in start order.
  defp started(acc \\ []) do
    receive do
      {:started, id} -> started([id | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  # The product's step, its answer reported to `test` before the tier
  # reads it.
  defp real(test) do
    fn ->
      answer = Cyfr.Application.declared_restore()
      send(test, {:answered, answer})
      answer
    end
  end

  defp refused(
         {:shutdown,
          {:failed_to_start_child, :barrier_infra,
           {:shutdown, {:failed_to_start_child, :declared_restore, {:restore_refused, class}}}}}
       ),
       do: class

  # ---------------------------------------------------------------------------
  # The rows a post-gate child would act on
  # ---------------------------------------------------------------------------

  defp hold_slot! do
    node = "node-barrier-#{System.unique_integer([:positive])}"
    {:ok, slot} = Arca.ControlPlane.take(node, "boot-#{node}", 60_000)
    slot
  end

  defp expire_slot!(slot) do
    past = DateTime.add(Arca.ServerMetaStorage.now!(), -1_000, :millisecond)

    {1, _} =
      Arca.Repo.update_all(from(l in Arca.Schemas.CellLease, where: l.node == ^slot.node),
        set: [lease_until: past]
      )

    :ok
  end

  defp admitting_rows! do
    ctx = Sanctum.TestContext.local(:prism)
    actor = Sanctum.Context.actor(ctx)
    n = System.unique_integer([:positive])

    {:ok, schedule} =
      Arca.CronSchedule.create(actor, %{
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        name: "barrier-#{n}",
        cron_expression: "* * * * *",
        reference: "reagent:local.barrier:1.0.0",
        resolved_reference: "reagent:local.barrier:1.0.0",
        profile_id: "prof_barrier",
        next_run_at: DateTime.add(DateTime.utc_now(), -5, :second),
        cap: 1_000
      })

    {:ok, thread} = Arca.ThreadStorage.create(actor)

    {:ok, %{turn: turn}} =
      Arca.TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: ctx.user_id, content: "@aqua go"},
        turn: %{agent: "aqua", requested_by: ctx.user_id, origin: :interactive}
      })

    {:ok, backend} =
      Arca.McpServerStorage.insert(actor, %{
        cap: 0,
        name: "barrier-#{n}",
        url: "http://127.0.0.1:9/mcp",
        enabled: true
      })

    %{
      actor: actor,
      schedule: schedule,
      turn: turn,
      backend: backend,
      topics: [
        Cyfr.Bus.executions(actor),
        Cyfr.Bus.schedule_runs(actor),
        Cyfr.Bus.thread(actor, thread.id)
      ]
    }
  end

  # Nothing acted on the rows: the schedule did not fire, the turn was not
  # recovered, the backend was not started.
  defp untouched!(%{actor: actor, schedule: schedule, turn: turn, backend: backend}) do
    assert {:ok, now_schedule} = Arca.CronSchedule.get(actor, schedule.id)
    assert now_schedule.next_run_at == schedule.next_run_at
    assert now_schedule.updated_at == schedule.updated_at

    assert Arca.Repo.one(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id, select: t.fence)) ==
             turn.fence

    assert {:ok, now_backend} = Arca.McpServerStorage.get_by_id(actor, backend.id)
    assert now_backend.epoch == backend.epoch
    assert Registry.lookup(Emissary.External.ServerRegistry, backend.id) == []

    refute_receive %Cyfr.Bus.Execution{kind: :started}
    refute_receive %Cyfr.Bus.ScheduleRun{kind: :fired}
    refute_receive %Cyfr.Bus.ThreadEvent{}
  end

  # A person's session, and the declared restore `cyfr restore` marked
  # once the backup's parts were back: the transition the step runs deletes
  # every session and the marker with it.
  defp declared_restore! do
    {:ok, person} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|barrier-#{System.unique_integer([:positive])}",
        provider: "github",
        verified: true
      })

    {:ok, session} =
      Sanctum.TestContext.create_session(
        Sanctum.Context.build(
          user_id: person.id,
          athanor_id: Sanctum.TestContext.athanor_id(),
          provider: "github",
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )
      )

    {:ok, restore_id} = Arca.SecurityTransitions.mark_restore(Prima.Actor.system())
    %{restore_id: restore_id, token: session.token}
  end

  # Whether the marker still names the restore, and the session still loads.
  defp restore_state(%{restore_id: restore_id, token: token}) do
    %{
      marker:
        Arca.Repo.exists?(
          from(m in Arca.Schemas.ServerMeta,
            where: m.key == "restore_pending" and m.value == ^restore_id
          )
        ),
      session: match?({:ok, _}, Sanctum.Session.load(token))
    }
  end
end
