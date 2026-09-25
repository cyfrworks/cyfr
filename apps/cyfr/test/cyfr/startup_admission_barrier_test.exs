# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.StartupAdmissionBarrierTest do
  @moduledoc """
  Startup order is the admission barrier: `Cyfr.Bootstrap` sits between
  the children the security reconcile needs and every child that admits
  work, and only its checked success lets the rest of the tree — and the
  endpoint after it — start.

  The census is read from `Cyfr.Application.tiers/0`, the list the boot
  starts, and pinned exactly: a child added before the gate, or moved
  across it, fails here until someone decides where it belongs.

  The barrier is exercised on that same list under a supervisor of the
  test's own. The real `Cyfr.Bootstrap` runs its real reconcile against
  the database, paused behind a barrier the test lifts; every other child
  is a stand-in that records being started, because the running suite's
  own tree already holds those names. With a due schedule, an open turn,
  an enabled backend and a delisted operator in the database, nothing
  after the gate starts, nothing is dispensed and nothing is published
  until the reconcile has committed, released and re-verified — and when
  it refuses (a claim a peer keeps, a release that does not land, a lost
  slot, a raise, a gate killed mid-reconcile), nothing after it ever does.
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
    EmissaryWeb.Telemetry,
    Phoenix.PubSub.Supervisor,
    Cyfr.StandingWatch,
    Cyfr.TelemetryBridge
  ]

  @post_gate [
    Cyfr.RetentionScheduler,
    Aqua.ScheduleNotes,
    Crucible.Schedules.TaskSupervisor,
    Crucible.Schedules.Scheduler,
    Crucible.Slots,
    Crucible.Tree,
    Crucible.TaskSupervisor,
    Crucible.ArchiveWatch,
    Crucible.Sweeper,
    Crucible.WorkerWatch,
    Crucible.HostListener,
    Emissary.MCP.SubscriptionRegistry,
    Emissary.External.ServerTree,
    Emissary.TaskSupervisor,
    Compendium.Builds.TaskSupervisor,
    Grimoire.RunningTasks,
    Grimoire.TaskSupervisor,
    Compendium.ProvisioningSupervisor,
    Compendium.Provisioning,
    Compendium.ProjectionReconciler,
    Prism.TinctureRegistry,
    Aqua.WorkerTree,
    Aqua.RunnerTree,
    Cyfr.SeedOffer
  ]

  @web [EmissaryWeb.Endpoint]

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
      [{Cyfr.InfraSupervisor, infra}, {Cyfr.WebSupervisor, web}] = Cyfr.Application.tiers()
      ids = Enum.map(infra, &id/1)

      {pre, [Cyfr.Bootstrap | post]} = Enum.split_while(ids, &(&1 != Cyfr.Bootstrap))

      assert pre == @pre_gate
      assert post == @post_gate
      assert Enum.map(web, &id/1) == @web

      # The gate is temporary: it answers once and leaves no process, and a
      # refusal it returns is the supervisor's failure to start.
      assert %{restart: :temporary} = infra |> Enum.find(&(id(&1) == Cyfr.Bootstrap)) |> spec()
      assert %{restart: :temporary} = infra |> Enum.find(&(id(&1) == Cyfr.SeedOffer)) |> spec()
    end

    test "only a test build with boot work switched off omits the gate" do
      refute Cyfr.Application.bootstrap_skipped?(false, false)
      refute Cyfr.Application.bootstrap_skipped?(false, true)
      refute Cyfr.Application.bootstrap_skipped?(true, true)
      assert Cyfr.Application.bootstrap_skipped?(true, false)

      Application.put_env(:cyfr, :provisioning_boot_enabled, false)
      [{_, infra}, _web] = Cyfr.Application.tiers()
      ids = Enum.map(infra, &id/1)
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
      assert started() == @post_gate ++ @web

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
      assert started() == @post_gate ++ @web
      refute platform?(delisted.user.id)
      stop_tree(starter)
    end
  end

  # ---------------------------------------------------------------------------
  # The tree, with stand-ins for every child but the gate
  # ---------------------------------------------------------------------------

  @doc false
  # A child's stand-in: records that the supervisor started it, and leaves
  # no process, so the running suite's own child of that name is untouched.
  def probe(id, test) do
    send(test, {:started, id})
    :ignore
  end

  defp start_tree!(bootstrap_opts) do
    test = self()
    [{_, infra}, {_, web}] = Cyfr.Application.tiers()

    root = [
      tier(:barrier_infra, Enum.map(infra, &stand_in(&1, test, bootstrap_opts))),
      tier(:barrier_web, Enum.map(web, &stand_in(&1, test, bootstrap_opts)))
    ]

    spawn(fn ->
      Process.flag(:trap_exit, true)
      send(test, {:tree, self(), Supervisor.start_link(root, strategy: :rest_for_one)})

      receive do
        :stop -> :ok
      end
    end)
  end

  defp stop_tree(starter) do
    ref = Process.monitor(starter)
    send(starter, :stop)
    assert_receive {:DOWN, ^ref, :process, ^starter, _}, 5_000
  end

  defp stand_in(child, test, bootstrap_opts) do
    case id(child) do
      Cyfr.Bootstrap ->
        Supervisor.child_spec({Cyfr.Bootstrap, bootstrap_opts}, restart: :temporary)

      id ->
        %{id: id, start: {__MODULE__, :probe, [id, test]}, restart: :temporary}
    end
  end

  defp tier(id, children) do
    %{
      id: id,
      start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
      type: :supervisor
    }
  end

  defp spec(child), do: Supervisor.child_spec(child, [])
  defp id(child), do: spec(child).id

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
