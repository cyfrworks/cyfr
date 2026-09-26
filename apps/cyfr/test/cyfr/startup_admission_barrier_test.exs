# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.StartupAdmissionBarrierTest do
  @moduledoc """
  Startup order is the admission barrier: `Cyfr.Bootstrap` sits between
  the children the security reconcile needs and every child that admits
  work, and only its checked success lets the rest of the tree — and the
  endpoint after it — start.

  The census is read from `Cyfr.Application.tiers/0`, the tree the boot
  starts down through every subtree, and pinned exactly: a child added
  before the gate, or moved across it or between subtrees, fails here
  until someone decides where it belongs.

  The barrier is exercised on that same list under a supervisor of the
  test's own. The real `Cyfr.Bootstrap` runs its real reconcile against
  the database, paused behind a barrier the test lifts; every other child
  is a stand-in that records being started and stopped, under supervisors
  built with the product's strategies and intensities, because the
  running suite's own tree already holds those names. With a due
  schedule, an open turn, an enabled backend and a delisted operator in
  the database, nothing after the gate starts, nothing is dispensed and
  nothing is published until the reconcile has committed, released and
  re-verified — and when it refuses (a claim a peer keeps, a release that
  does not land, a lost slot, a raise, a gate killed mid-reconcile),
  nothing after it ever does.

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

  alias Arca.JobClaims
  alias Sanctum.Tenancy.{Members, Users}

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
    Arca.SchemaFingerprint.Check,
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

  # A supervisor the census describes is `{id, children}`, in start order.
  @post_gate [
    Cyfr.RetentionScheduler,
    CyfrWeb.SSE.Registry,
    {Grimoire.Supervisor, [Grimoire.RunningTasks, Grimoire.TaskSupervisor]},
    {Compendium.Supervisor,
     [
       Compendium.Builds.TaskSupervisor,
       Compendium.ProvisioningSupervisor,
       Compendium.Provisioning,
       Compendium.ProjectionReconciler
     ]},
    {Crucible.Supervisor,
     [
       Crucible.Slots,
       {Crucible.Tree,
        [
          Crucible.Registry,
          Crucible.Events.Registry,
          Crucible.Events.Sequence,
          Crucible.Events.Supervisor,
          Crucible.Attempt.Registry,
          Crucible.Attempt.Supervisor
        ]},
       Crucible.TaskSupervisor,
       Crucible.ArchiveWatch,
       Crucible.Sweeper,
       Crucible.WorkerWatch,
       Crucible.HostListener
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
    Crucible.Schedules.TaskSupervisor,
    Crucible.Schedules.Scheduler,
    Prism.TinctureRegistry,
    Prism.TaskSupervisor,
    Cyfr.SeedOffer
  ]

  # Every supervisor the census describes, with its strategy and its
  # restart intensity.
  @supervisors %{
    Cyfr.InfraSupervisor => {:rest_for_one, {10, 60}},
    Cyfr.WebSupervisor => {:one_for_one, {10, 60}},
    Grimoire.Supervisor => {:rest_for_one, {10, 60}},
    Compendium.Supervisor => {:one_for_one, {10, 60}},
    Crucible.Supervisor => {:rest_for_one, {10, 60}},
    Crucible.Tree => {:rest_for_one, {10, 60}},
    Aqua.Supervisor => {:rest_for_one, {10, 60}},
    Aqua.WorkerTree => {:rest_for_one, {10, 60}},
    Aqua.RunnerTree => {:rest_for_one, {10, 60}},
    Emissary.Supervisor => {:one_for_one, {10, 60}},
    Emissary.External.ServerTree => {:rest_for_one, {10, 60}}
  }

  @web [CyfrWeb.Ingress.TaskSupervisor, CyfrWeb.Endpoint]

  # The order a stop of the whole tree stops every lasting child in: the
  # web tier, the console, the schedule pair, then the domains in reverse
  # (the host API listener before the attempt tree it reaches), and the
  # foundations down to the cell.
  @stop_order [
    CyfrWeb.Endpoint,
    CyfrWeb.Ingress.TaskSupervisor,
    Prism.TaskSupervisor,
    Prism.TinctureRegistry,
    Crucible.Schedules.Scheduler,
    Crucible.Schedules.TaskSupervisor,
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
    Crucible.HostListener,
    Crucible.WorkerWatch,
    Crucible.Sweeper,
    Crucible.ArchiveWatch,
    Crucible.TaskSupervisor,
    Crucible.Attempt.Supervisor,
    Crucible.Attempt.Registry,
    Crucible.Events.Supervisor,
    Crucible.Events.Sequence,
    Crucible.Events.Registry,
    Crucible.Registry,
    Crucible.Slots,
    Compendium.ProjectionReconciler,
    Compendium.Provisioning,
    Compendium.ProvisioningSupervisor,
    Compendium.Builds.TaskSupervisor,
    Grimoire.TaskSupervisor,
    Grimoire.RunningTasks,
    CyfrWeb.SSE.Registry,
    Cyfr.RetentionScheduler,
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
    Cyfr.Cell,
    Cyfr.RetentionScheduler,
    Crucible.WorkerWatch,
    Emissary.External.Backends
  ]

  # The leaves the product starts no lasting process for: the one-shot
  # checks and offers answer `:ignore`, and the recovery task exits once it
  # has run. Their stand-ins record the start and leave no process either.
  @no_process [
    Arca.SchemaFingerprint.Check,
    Cyfr.KeyringFingerprint.Check,
    Aqua.RunnerRecovery,
    Cyfr.SeedOffer
  ]

  # The children a rest_for_one restart from `Cyfr.Cell` starts before the
  # gate, in order.
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

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    saved_env = for {app, key, _} <- @flags, do: {app, key, Application.fetch_env(app, key)}
    saved_emails = Application.fetch_env(:sanctum, :platform_admin_emails)
    saved_terms = Map.new(@control_plane_keys, &{&1, :persistent_term.get(&1, :absent)})

    for {app, key, value} <- @flags, do: Application.put_env(app, key, value)
    Application.put_env(:sanctum, :platform_admin_emails, [])

    on_exit(fn ->
      for {app, key, saved} <- [{:sanctum, :platform_admin_emails, saved_emails} | saved_env] do
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

    {:ok, key: "cell-barrier-#{System.unique_integer([:positive])}"}
  end

  describe "the census" do
    test "only the reconcile's needs start before the gate; everything that admits work after it" do
      tiers = Cyfr.Application.tiers()

      [{Cyfr.InfraSupervisor, _, _, infra}, {Cyfr.WebSupervisor, _, _, web}] = tiers
      ids = Enum.map(infra, &shape/1)

      {pre, [Cyfr.Bootstrap | post]} = Enum.split_while(ids, &(&1 != Cyfr.Bootstrap))

      assert pre == @pre_gate
      assert post == @post_gate
      assert Enum.map(web, &shape/1) == @web
      assert Map.new(Enum.flat_map(tiers, &strategies/1)) == @supervisors

      # The gate is transient: it answers once and leaves no process, stays
      # listed, and runs again on every restart of what precedes it; a
      # refusal it returns is the supervisor's failure to start. The offer
      # is temporary: it runs once, at boot.
      assert %{restart: :transient} = infra |> Enum.find(&(shape(&1) == Cyfr.Bootstrap)) |> spec()
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
      refute Cyfr.Bootstrap in ids
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
    setup %{key: key} do
      slot = hold_slot!()
      rows = admitting_rows!()
      delisted = delisted_operator!()

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

      {:ok, slot: slot, rows: rows, delisted: delisted, key: key}
    end

    test "nothing that admits work starts, is dispensed or is published until the gate returns",
         %{key: key, rows: rows, delisted: delisted} do
      starter = start_tree!(key: key, reconcile: paused(self()))
      assert_receive {:paused, gate}, 5_000

      assert started() == @pre_gate
      refute_receive {:started, _}, 300
      refute_receive {:credential, _}
      refute_receive {:tree, _, _}
      untouched!(rows)
      assert platform?(delisted.user.id), "the reconcile committed before its barrier lifted"

      send(gate, {:lift, &Sanctum.reconcile_platform_admins/2})

      assert_receive {:tree, ^starter, {:ok, _root}}, 10_000
      # The endpoint is last: it starts only after the gate returned and
      # every child that admits work is up.
      assert started() == leaves(@post_gate) ++ @web

      refute platform?(delisted.user.id)
      assert {:error, _} = Sanctum.Session.load(delisted.token, surface: :console)
      refute_receive {:credential, _}
      stop_tree(starter)
    end

    test "a peer that keeps the claim past the wait refuses the boot, and nothing after starts",
         %{key: key, delisted: delisted} do
      {:ok, _peer} = JobClaims.claim("bootstrap", key, "member-b", 60_000)

      starter = start_tree!(key: key, wait_ms: 300)
      assert_receive {:tree, ^starter, {:error, reason}}, 10_000
      assert refused(reason) == :busy
      assert started() == @pre_gate
      assert platform?(delisted.user.id)
      stop_tree(starter)
    end

    test "a release that does not land, a lost slot or a raise refuses it the same way", %{
      key: key,
      slot: slot,
      delisted: delisted
    } do
      failures = [
        release_failed: fn claim, opts ->
          {:ok, renewed} = Sanctum.reconcile_platform_admins(claim, opts)
          {:ok, _moved} = JobClaims.record(renewed, "a peer's write")
          {:ok, renewed}
        end,
        slot_lost: fn claim, opts ->
          expire_slot!(slot)
          Sanctum.reconcile_platform_admins(claim, opts)
        end,
        exception: fn _claim, _opts -> raise "boom" end
      ]

      for {class, lift} <- failures do
        starter = start_tree!(key: key, reconcile: paused(self()))
        assert_receive {:paused, gate}, 5_000
        assert started() == @pre_gate
        refute_receive {:started, _}, 200

        send(gate, {:lift, lift})
        assert_receive {:tree, ^starter, {:error, reason}}, 10_000
        assert refused(reason) == class
        refute_receive {:started, _}, 100
        refute_receive {:credential, _}
        stop_tree(starter)
      end

      # The first failure committed its reconcile before its release did
      # not land; the boot was refused all the same.
      refute platform?(delisted.user.id)
    end

    test "a gate killed mid-reconcile starts nothing, and the next start reconciles first", %{
      key: key,
      delisted: delisted
    } do
      starter = start_tree!(key: key, reconcile: paused(self()))
      assert_receive {:paused, gate}, 5_000
      assert started() == @pre_gate

      Process.exit(gate, :kill)
      assert_receive {:tree, ^starter, {:error, _reason}}, 10_000
      refute_receive {:started, _}, 200
      assert platform?(delisted.user.id)
      stop_tree(starter)

      # The restarted tree runs the gate again from the start, under the
      # claim its dead predecessor took for this same boot.
      starter = start_tree!(key: key, reconcile: paused(self()))
      assert_receive {:paused, gate}, 5_000
      assert started() == @pre_gate
      refute_receive {:started, _}, 200

      send(gate, {:lift, &Sanctum.reconcile_platform_admins/2})
      assert_receive {:tree, ^starter, {:ok, _root}}, 10_000
      assert started() == leaves(@post_gate) ++ @web
      refute platform?(delisted.user.id)
      stop_tree(starter)
    end
  end

  describe "a restart after boot" do
    setup %{key: key} do
      slot = hold_slot!()
      rows = admitting_rows!()
      {:ok, slot: slot, rows: rows, key: key}
    end

    @tag :capture_log
    test "an endpoint crash loop restarts the web tier alone, and no healthy domain", %{key: key} do
      {starter, root} = booted!(key)
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
    test "a restarted infra tier serves the operation table this boot built", %{key: key} do
      operations = Grimoire.operations()
      {starter, root} = booted!(key)

      kill!(root, [:barrier_infra, Cyfr.Cell])
      next_started!(@from_cell)
      assert_receive {:paused, gate}, 5_000
      send(gate, {:lift, &Sanctum.reconcile_platform_admins/2})
      next_started!(restarting(@post_gate))

      assert Grimoire.operations() === operations
      assert :persistent_term.get({Grimoire, :operations}) === operations
      stop_tree(starter)
    end

    test "the operation table and its index are written by the catalog's load alone" do
      lib = Path.expand("../../lib", __DIR__)

      sources =
        for path <- Path.wildcard(Path.join(lib, "**/*.ex")),
            into: %{},
            do: {Path.relative_to(path, lib), File.read!(path)}

      writers = for {path, source} <- sources, grimoire_term_put?(source), do: path
      assert Enum.sort(writers) == ["grimoire/catalog.ex", "grimoire/resources.ex"]

      # The index's writer is a helper, and the catalog is its one caller.
      callers = for {path, source} <- sources, source =~ ~r/Resources\.put[(\/]/, do: path
      assert callers == ["grimoire/catalog.ex"]
    end

    @tag :capture_log
    test "a partial infra restart reruns the gate before anything that admits work", %{
      key: key,
      rows: rows
    } do
      {starter, root} = booted!(key)

      # From the cell down: nothing before it restarts, the gate reruns
      # before anything after it, and while it is paused nothing acts.
      kill!(root, [:barrier_infra, Cyfr.Cell])
      next_started!(@from_cell)
      assert_receive {:paused, gate}, 5_000
      quiet!()
      untouched!(rows)

      send(gate, {:lift, &Sanctum.reconcile_platform_admins/2})
      next_started!(restarting(@post_gate))
      quiet!()

      # The gate is the product's transient child: once its rerun has
      # answered it stays listed, with no process, for the next cascade.
      infra = pid_at(root, [:barrier_infra])
      assert {:ok, %{restart: :transient}} = :supervisor.get_childspec(infra, Cyfr.Bootstrap)

      assert {Cyfr.Bootstrap, :undefined, :worker, _} =
               infra |> Supervisor.which_children() |> List.keyfind(Cyfr.Bootstrap, 0)

      # From a domain after the gate: only what follows it restarts, and
      # the gate does not run.
      kill!(root, [:barrier_infra, Compendium.Supervisor])

      next_started!(
        restarting(Enum.drop_while(@post_gate, &(id_of(&1) != Compendium.Supervisor)))
      )

      quiet!()
      refute_received {:paused, _}

      # A rerun that keeps refusing fails the tier, whose restart by the
      # root runs the gate in the tier's own start and fails it again,
      # until the root gives up too.
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
      key: key,
      slot: slot
    } do
      boot = Prima.Boot.id()
      {starter, root} = booted!(key)

      kill!(root, [:barrier_infra, Cyfr.Cell])
      next_started!(@from_cell)
      assert_receive {:paused, gate}, 5_000
      send(gate, {:lift, &Sanctum.reconcile_platform_admins/2})
      next_started!(restarting(@post_gate))
      assert Prima.Boot.id() == boot

      expire_slot!(slot)
      kill!(root, [:barrier_infra, Cyfr.Cell])
      next_started!(@from_cell)
      assert_receive {:paused, gate}, 5_000
      ref = Process.monitor(gate)
      send(gate, {:lift, &Sanctum.reconcile_platform_admins/2})
      assert_receive {:DOWN, ^ref, :process, ^gate, {:bootstrap_refused, :slot_lost}}, 5_000

      # The tier tries the gate again; nothing after it starts meanwhile.
      assert_receive {:paused, retry}, 5_000
      quiet!()
      stop_tree(starter, [retry])
    end

    # The servers release their owners through the controller, so a
    # controller that dies takes them down and starts them again after
    # it, with the reconciler that fills them; the registry before it,
    # and everything outside the group, keep running.
    @tag :capture_log
    test "a dead backends controller restarts the servers it releases, and nothing else", %{
      key: key
    } do
      {starter, root} = booted!(key)
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

    test "runs the start backwards, and every claim holder is down before its tier returns", %{
      key: key
    } do
      {starter, root} = booted!(key)
      infra = pid_at(root, [:barrier_infra])

      # The gate answered and left no process: its claim was released
      # before the tier went on, and nothing of it is left to stop.
      assert {Cyfr.Bootstrap, :undefined, :worker, _} =
               infra |> Supervisor.which_children() |> List.keyfind(Cyfr.Bootstrap, 0)

      infra_ref = Process.monitor(infra)
      :ok = Supervisor.stop(root)
      stops = stops(infra_ref)

      assert stops -- [:infra_down] == @stop_order
      assert @stop_order == Enum.reverse(@pre_gate ++ leaves(@post_gate) ++ @web) -- @no_process

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
  # The tree, with stand-ins for every child but the gate
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

  # The tiers under a root with the product root's strategy and intensity
  # (`Cyfr.Supervisor`), and under ids of the test's own, so a refusal
  # names them. The starter reports the root's exit and stops the tree
  # when told to.
  defp start_tree!(bootstrap_opts) do
    test = self()
    [infra, web] = Cyfr.Application.tiers()

    root = [
      %{stand_in(infra, test, bootstrap_opts) | id: :barrier_infra},
      %{stand_in(web, test, bootstrap_opts) | id: :barrier_web}
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

  # A gate paused while the tree stops would hold its tier's shutdown for
  # good: the gates the test holds, and any the tier starts meanwhile, are
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

  # A tree whose gate ran the real reconcile, with every start drained.
  defp booted!(key) do
    starter = start_tree!(key: key, reconcile: paused(self()))
    assert_receive {:paused, gate}, 5_000
    send(gate, {:lift, &Sanctum.reconcile_platform_admins/2})
    assert_receive {:tree, ^starter, {:ok, root}}, 10_000
    assert started() == @pre_gate ++ leaves(@post_gate) ++ @web
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

  # Whether `source` writes a `:persistent_term` key `{Grimoire, _}`, given
  # literally or through a module attribute bound to one.
  defp grimoire_term_put?(source) do
    attributes =
      for [name] <- Regex.scan(~r/@(\w+)\s+\{Grimoire,/, source, capture: :all_but_first),
          do: "@" <> name

    source
    |> then(&Regex.scan(~r/:persistent_term\.put\(\s*([^,]+),/, &1, capture: :all_but_first))
    |> Enum.any?(fn [key] ->
      String.starts_with?(key, "{Grimoire,") or String.trim(key) in attributes
    end)
  end

  # Lifts every rerun with a raise until the root gives up, answering the
  # root's exit reason and the tier each rerun ran under, in order.
  defp refuse_until_root_exits(starter, tiers \\ []) do
    receive do
      {:paused, gate} ->
        {:dictionary, dictionary} = Process.info(gate, :dictionary)
        [tier | _] = Keyword.fetch!(dictionary, :"$ancestors")
        send(gate, {:lift, fn _claim, _opts -> raise "boom" end})
        refuse_until_root_exits(starter, [tier | tiers])

      {:tree_exit, ^starter, reason} ->
        {reason, Enum.reverse(tiers)}
    after
      10_000 -> flunk("the root did not give up")
    end
  end

  # A supervisor the census describes is built, unnamed, with the
  # product's strategy and intensity over its children's stand-ins.
  defp stand_in({id, strategy, {max_restarts, max_seconds}, children}, test, bootstrap_opts) do
    %{
      id: id,
      start:
        {Supervisor, :start_link,
         [
           Enum.map(children, &stand_in(&1, test, bootstrap_opts)),
           [strategy: strategy, max_restarts: max_restarts, max_seconds: max_seconds]
         ]},
      type: :supervisor
    }
  end

  # A leaf keeps the product's id, restart and shutdown: the gate is the
  # real one, a leaf the product leaves no process for is the probe, and
  # every other leaf is a live stand-in.
  defp stand_in(child, test, bootstrap_opts) do
    spec = child |> spec() |> Map.take([:id, :restart, :shutdown, :type])

    start =
      case spec.id do
        Cyfr.Bootstrap -> {Cyfr.Bootstrap, :start_link, [bootstrap_opts]}
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

  # A reconcile that announces itself and waits for the test to hand it
  # the work to do: the real reconcile, or a failure.
  defp paused(test) do
    fn claim, opts ->
      send(test, {:paused, self()})

      receive do
        {:lift, work} -> work.(claim, opts)
      end
    end
  end

  defp refused(
         {:shutdown,
          {:failed_to_start_child, :barrier_infra,
           {:shutdown, {:failed_to_start_child, Cyfr.Bootstrap, {:bootstrap_refused, class}}}}}
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
    ctx = Sanctum.TestContext.local()
    actor = Sanctum.Context.actor(ctx)
    n = System.unique_integer([:positive])

    {:ok, schedule} =
      Arca.CronSchedule.create(%{
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        name: "barrier-#{n}",
        cron_expression: "* * * * *",
        reference: "reagent:local.barrier:1.0.0",
        resolved_reference: "reagent:local.barrier:1.0.0",
        profile_id: "prof_barrier",
        next_run_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

    {:ok, thread} = Arca.ThreadStorage.create(actor)

    {:ok, %{turn: turn}} =
      Arca.TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: ctx.user_id, content: "@aqua go"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    {:ok, backend} =
      Arca.McpServerStorage.insert(actor, %{
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

  defp delisted_operator! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|barrier-#{n}",
        provider: "github",
        email: "barrier#{n}@example.com",
        verified: true
      })

    {:ok, _} = Members.ensure_platform(user.id)

    {:ok, session} =
      Sanctum.TestContext.create_session(
        Sanctum.Context.build(
          user_id: user.id,
          athanor_id: Sanctum.TestContext.athanor_id(),
          provider: "github",
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )
      )

    %{user: user, token: session.token}
  end

  defp platform?(user_id) do
    {:ok, rows} = Members.list_by_user(user_id)
    Enum.any?(rows, &(&1.scope == "platform"))
  end
end
