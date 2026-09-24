# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.WorkerWatchTest do
  @moduledoc """
  The worker watch hears from each configured worker service every poll
  interval and lapses what a boot the cell stopped hearing from, or saw
  replaced, was running: three misses in a row lapse the recorded boot's
  running attempts once, publishing `execution.lapsed`, and lapse nothing
  more until a status names a boot again; a status naming a new boot
  lapses the old boot's attempts once; a status heard between misses
  lapses nothing; a status of another service, of another shape or none
  at all is a miss; and a member that holds no slot in the cell polls
  nothing.

  Writing is claimed and reading is free. A miss records its count under
  the claim's fence and renews nothing, so a member that stops hearing a
  service loses the watch within one lease and what it wrote is inherited
  at the next fence; a member that can hear the service takes the watch
  over and puts the count back to zero, so a member cut off from a
  service its peers can reach never reaches the threshold and lapses
  nothing. A service no member has ever heard opens no claim at all.

  Two terminal writers for one attempt leave one terminal row and give
  its capacity back once. The bounds are validated when the watch starts,
  and dispatch addresses a start to the boot the watch heard within one
  poll interval.
  """

  use ExUnit.Case, async: false

  import Prima.Test.Wait

  alias Cyfr.Execution.{Attempt, Dispatch, Lapse, WorkerWatch}
  alias Prima.Slots
  alias Cyfr.Test.{AttemptFixtures, ScriptedWorkerListener}

  @moduletag :capture_log

  @service "wrk_watch"
  @slots Cyfr.Execution.Slots
  @lapsed "Execution terminated: runner stopped without cleanup"
  @poll_ms 40
  @watch :worker_watch_under_test
  @not_a_status %{"no" => "status"}

  # A worker service whose status answers from a script the test sets: a
  # list consumed in order whose last item answers every later request.
  # Each request is reported to the test with what it answered.
  defmodule Worker do
    @moduledoc false
    @behaviour Prima.WorkerAPI

    def script!(test, items) when is_pid(test) and is_list(items) and items != [],
      do: Agent.update(__MODULE__, fn _state -> %{test: test, script: items} end)

    @impl true
    def start(_token, _input, _sealed_keys), do: {:error, :malformed}

    @impl true
    def kill(_execution_id), do: {:error, :not_found}

    @impl true
    def status do
      {test, answer} =
        Agent.get_and_update(__MODULE__, fn
          %{script: [answer]} = state -> {{state.test, answer}, state}
          %{script: [answer | rest]} = state -> {{state.test, answer}, %{state | script: rest}}
        end)

      send(test, {:status_asked, answer})
      {:ok, answer}
    end
  end

  # The same worker service as `Worker`, on a listener of its own: what a
  # member that can still reach the service sees while another cannot.
  defmodule Peer do
    @moduledoc false
    @behaviour Prima.WorkerAPI

    def script!(test, items) when is_pid(test) and is_list(items) and items != [],
      do: Agent.update(__MODULE__, fn _state -> %{test: test, script: items} end)

    @impl true
    def start(_token, _input, _sealed_keys), do: {:error, :malformed}

    @impl true
    def kill(_execution_id), do: {:error, :not_found}

    @impl true
    def status do
      {test, answer} =
        Agent.get_and_update(__MODULE__, fn
          %{script: [answer]} = state -> {{state.test, answer}, state}
          %{script: [answer | rest]} = state -> {{state.test, answer}, %{state | script: rest}}
        end)

      send(test, {:peer_status_asked, answer})
      {:ok, answer}
    end
  end

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  # Serve `Worker` with `script` on a loopback port; answers its endpoint.
  defp serve!(script), do: serve!(Worker, script)

  defp serve!(worker, script) do
    test = self()

    start_supervised!(%{
      id: worker,
      start: {Agent, :start_link, [fn -> %{test: test, script: script} end, [name: worker]]}
    })

    listener = start_supervised!({ScriptedWorkerListener, worker: worker, service: @service})
    ScriptedWorkerListener.endpoint(listener, @service)
  end

  # Start a watch over `endpoint` with a fast poll; answers its name.
  defp watch!(endpoint, opts \\ []) do
    opts = Keyword.merge([workers: [endpoint], poll_ms: @poll_ms, misses: 3, name: @watch], opts)
    name = Keyword.fetch!(opts, :name)
    start_supervised!(Supervisor.child_spec({WorkerWatch, opts}, id: name))
    name
  end

  # The `job_claims` row the watch of `@service` is held by, or nil.
  defp claim_row do
    case Arca.JobClaims.read("worker_watch", @service) do
      {:ok, row} -> row
      {:error, :not_found} -> nil
    end
  end

  defp claim_detail(%{detail: detail}), do: Jason.decode!(detail)

  defp status(boot, attempts \\ [], overrides \\ %{}) do
    Map.merge(
      %{
        service: @service,
        boot: boot,
        runners: %{fresh: 0, idle: 0, busy: length(attempts), tainted: 0},
        attempts: attempts,
        memory_bytes: nil,
        refusal: nil
      },
      overrides
    )
  end

  defp attached!(ctx, boot),
    do: AttemptFixtures.attached!(ctx: ctx, service_id: @service, boot_id: boot)

  defp row(fixture), do: Arca.Repo.get!(Arca.Schemas.Execution, fixture.execution_id)

  defp attempt_row(fixture),
    do: Arca.ExecutionAttempts.get(Prima.Actor.in_athanor(fixture.athanor_id), fixture.attempt)

  defp seen(watch), do: Map.fetch!(WorkerWatch.seen(watch), @service)

  # Wait for `count` more misses than the watch has now.
  defp misses!(watch, count) do
    misses = seen(watch).misses
    wait_until(fn -> seen(watch).misses >= misses + count end, 2_000, "#{count} more misses")
  end

  describe "misses" do
    test "three in a row lapse the last heard boot's running attempts once, publishing execution.lapsed",
         %{ctx: ctx} do
      fixture = attached!(ctx, "boot_1")
      :ok = Cyfr.Execution.Events.subscribe(fixture.execution_id, ctx)
      endpoint = serve!([status("boot_1", [fixture.attempt])])
      watch = watch!(endpoint)

      wait_until(fn -> WorkerWatch.fresh_boot(endpoint, watch) == {:ok, "boot_1"} end)
      assert %{boot: "boot_1", attempts: [_], misses: 0, lapsed: false} = seen(watch)

      Worker.script!(self(), [@not_a_status])

      assert {:error, @lapsed} = Dispatch.await(fixture.pid, fixture.close)
      assert %{status: "failed", error_message: @lapsed} = row(fixture)
      assert %{state: "lapsed", outcome: "uncertain", boot_id: "boot_1"} = attempt_row(fixture)
      execution_id = fixture.execution_id

      assert_receive %Cyfr.Bus.ExecutionEvent{
        type: "execution.lapsed",
        execution_id: ^execution_id
      }

      assert %{boot: "boot_1", misses: misses, lapsed: true} = seen(watch)
      assert misses >= 3
      assert WorkerWatch.fresh_boot(endpoint, watch) == :unknown

      # Further misses lapse nothing more: an attempt of the boot opened
      # since stays running until a status names the boot again.
      later = attached!(ctx, "boot_1")
      misses!(watch, 3)
      assert %{status: "running"} = row(later)
      assert Process.alive?(later.pid)
      refute_received %Cyfr.Bus.ExecutionEvent{type: "execution.lapsed"}

      Worker.script!(self(), [status("boot_1", [later.attempt]), @not_a_status])
      assert {:error, @lapsed} = Dispatch.await(later.pid, later.close)
      assert %{status: "failed", error_message: @lapsed} = row(later)
    end

    test "two and then a status lapse nothing", %{ctx: ctx} do
      fixture = attached!(ctx, "boot_1")
      heard = status("boot_1", [fixture.attempt])
      endpoint = serve!([heard, @not_a_status, @not_a_status, heard])
      watch = watch!(endpoint)

      assert_receive {:status_asked, ^heard}, 1_000
      assert_receive {:status_asked, @not_a_status}, 1_000
      assert_receive {:status_asked, @not_a_status}, 1_000
      assert_receive {:status_asked, ^heard}, 1_000
      wait_until(fn -> match?(%{boot: "boot_1", misses: 0, lapsed: false}, seen(watch)) end)

      # Polls go on, every one heard.
      for _poll <- 1..3, do: assert_receive({:status_asked, ^heard}, 1_000)
      assert %{status: "running"} = row(fixture)
      assert Process.alive?(fixture.pid)

      # The entry is published when the answer is recorded, one round trip
      # after the request the test just saw; the window it stays fresh in
      # is one poll interval, so the condition is waited for and not read
      # off the instant the request landed.
      wait_until(fn -> WorkerWatch.fresh_boot(endpoint, watch) == {:ok, "boot_1"} end)
    end

    test "a status of another service, or of another shape, is a miss", %{ctx: ctx} do
      fixture = attached!(ctx, "boot_1")
      endpoint = serve!([status("boot_1", [fixture.attempt])])
      watch = watch!(endpoint)
      wait_until(fn -> WorkerWatch.fresh_boot(endpoint, watch) == {:ok, "boot_1"} end)

      elsewhere = status("boot_1", [fixture.attempt], %{service: "wrk_elsewhere"})
      malformed = status("boot_1", [fixture.attempt], %{runners: %{fresh: -1}})
      Worker.script!(self(), [elsewhere, malformed, elsewhere])

      assert {:error, @lapsed} = Dispatch.await(fixture.pid, fixture.close)
      assert %{status: "failed", error_message: @lapsed} = row(fixture)
      assert %{lapsed: true} = seen(watch)
    end

    test "a worker service that cannot be reached is a miss, and one never heard from takes no watch" do
      id = "wrk_unreached_#{System.unique_integer([:positive])}"
      endpoint = %{id: id, url: "http://127.0.0.1:19", components: nil}
      watch = watch!(endpoint, misses: 2)

      # This member's own unheard answers rise; the cell's count does not,
      # because a miss never takes a watch. There is no boot to lapse and
      # no member that ever heard one, so no row is opened at all — the
      # key is this test's own, so what is measured is this test's run.
      wait_until(fn -> WorkerWatch.seen(watch)[id].unheard >= 4 end, 2_000)

      assert %{boot: nil, attempts: [], misses: 0, lapsed: false, claimed: false} =
               WorkerWatch.seen(watch)[id]

      assert Arca.JobClaims.read("worker_watch", id) == {:error, :not_found}
      assert WorkerWatch.fresh_boot(endpoint, watch) == :unknown
    end
  end

  describe "the claimed watch" do
    test "a miss records its count without renewing, and a takeover reads the same count", %{
      ctx: ctx
    } do
      fixture = attached!(ctx, "boot_1")
      endpoint = serve!([status("boot_1", [fixture.attempt])])
      watch = watch!(endpoint, owner: "member_a")

      wait_until(fn -> match?(%{boot: "boot_1", misses: 0, claimed: true}, seen(watch)) end)
      held = claim_row()
      assert held.owner == "member_a"
      assert claim_detail(held)["boot"] == "boot_1"

      # From here this member hears nothing from the service.
      Worker.script!(self(), [@not_a_status])
      wait_until(fn -> seen(watch).misses >= 1 end, 2_000, "a miss to be counted")

      missed = claim_row()
      assert missed.owner == "member_a"
      assert missed.fence > held.fence, "the miss is written under a fence of its own"
      assert claim_detail(missed)["misses"] >= 1
      assert claim_detail(missed)["boot"] == "boot_1"

      # The whole mechanism: the write landed and the lease did not move,
      # so the watch runs out under a member that cannot hear the service.
      assert DateTime.compare(missed.lease_until, held.lease_until) == :eq

      # A clean stop gives the row up with its evidence intact, and the
      # next member takes it over at the next fence reading the same
      # count — the inheritance a partitioned successor depends on.
      :ok = stop_supervised(watch)
      released = claim_row()
      assert released.owner == "member_a"
      refute Arca.JobClaims.live?(released)

      assert {:ok, taken} = Arca.JobClaims.claim("worker_watch", @service, "member_b", 10_000)
      assert taken.owner == "member_b"
      assert taken.fence > released.fence
      assert claim_detail(taken) == claim_detail(released)
    end

    test "a member that hears the service takes the watch from one that cannot, and resets the count",
         %{ctx: ctx} do
      fixture = attached!(ctx, "boot_1")
      :ok = Cyfr.Execution.Events.subscribe(fixture.execution_id, ctx)
      heard = status("boot_1", [fixture.attempt])

      # One service, two members: each reaches it through a listener of
      # its own, and only one of them keeps hearing it.
      blind = serve!(Worker, [heard])
      seeing = serve!(Peer, [heard])

      cut_off = watch!(blind, owner: "member_a", name: :watch_member_a)
      wait_until(fn -> match?(%{owner: "member_a"}, claim_row()) end)

      Worker.script!(self(), [@not_a_status])
      hearing = watch!(seeing, owner: "member_b", name: :watch_member_b)

      # Within one lease the watch moves to the member that can hear, and
      # the count its predecessor left is reset rather than carried on.
      wait_until(
        fn -> match?(%{owner: "member_b"}, claim_row()) end,
        2_000,
        "the member that hears the service to take the watch"
      )

      # The cut-off member goes on missing, well past the threshold of
      # three, and lapses nothing: the count is the cell's, and the member
      # that hears the service keeps putting it back to zero.
      wait_until(
        fn -> WorkerWatch.seen(cut_off)[@service].unheard >= 9 end,
        2_000,
        "nine unheard answers on the cut-off member"
      )

      assert %{claimed: false} = WorkerWatch.seen(cut_off)[@service]
      assert %{claimed: true, boot: "boot_1"} = WorkerWatch.seen(hearing)[@service]

      row = claim_row()
      assert row.owner == "member_b"
      assert claim_detail(row)["misses"] == 0
      assert claim_detail(row)["lapsed"] == false

      assert %{status: "running"} = row(fixture)
      assert Process.alive?(fixture.pid)
      refute_received %Cyfr.Bus.ExecutionEvent{type: "execution.lapsed"}
    end
  end

  describe "a boot change" do
    test "lapses the old boot's attempts once, and the same status again lapses nothing more",
         %{ctx: ctx} do
      old = attached!(ctx, "boot_1")
      :ok = Cyfr.Execution.Events.subscribe(old.execution_id, ctx)
      endpoint = serve!([status("boot_1", [old.attempt])])
      watch = watch!(endpoint)
      wait_until(fn -> WorkerWatch.fresh_boot(endpoint, watch) == {:ok, "boot_1"} end)

      Worker.script!(self(), [status("boot_2")])

      assert {:error, @lapsed} = Dispatch.await(old.pid, old.close)
      assert %{status: "failed", error_message: @lapsed} = row(old)
      assert %{state: "lapsed", outcome: "uncertain", boot_id: "boot_1"} = attempt_row(old)
      old_id = old.execution_id
      assert_receive %Cyfr.Bus.ExecutionEvent{type: "execution.lapsed", execution_id: ^old_id}
      wait_until(fn -> WorkerWatch.fresh_boot(endpoint, watch) == {:ok, "boot_2"} end)
      assert %{boot: "boot_2", attempts: [], misses: 0, lapsed: false} = seen(watch)

      # The new boot's attempts are its own, through as many identical
      # statuses as come.
      new = attached!(ctx, "boot_2")
      heard = status("boot_2")
      for _poll <- 1..4, do: assert_receive({:status_asked, ^heard}, 1_000)
      assert %{status: "running"} = row(new)
      assert Process.alive?(new.pid)
      assert %{boot: "boot_2", misses: 0, lapsed: false} = seen(watch)
      refute_received %Cyfr.Bus.ExecutionEvent{type: "execution.lapsed"}
    end
  end

  describe "ownership" do
    test "a boot that does not own the control plane polls nothing and lapses nothing", %{
      ctx: ctx
    } do
      fixture = attached!(ctx, "boot_1")
      endpoint = serve!([@not_a_status])
      Arca.ControlPlane.record(:lost)
      on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)
      watch = watch!(endpoint)

      refute_receive {:status_asked, _answer}, 6 * @poll_ms
      assert %{boot: nil, misses: 0, lapsed: false} = seen(watch)
      assert %{status: "running"} = row(fixture)

      # Ownership regained, the next tick polls.
      Arca.ControlPlane.record(:unclaimed)
      assert_receive {:status_asked, _answer}, 1_000
    end
  end

  describe "two terminal writers for one attempt" do
    test "leave one terminal row, and give its capacity back once", %{ctx: ctx} do
      for round <- 1..3 do
        fixture = attached!(ctx, "boot_1")
        before = Slots.status(@slots).active
        :ok = Attempt.take_slot(fixture.pid, :root, 1_000)
        assert Slots.status(@slots).active == before + 1

        outcome =
          AttemptFixtures.outcome(fixture, "completed", %{"output" => %{"round" => round}})

        complete =
          Task.async(fn -> AttemptFixtures.call(fixture, "complete", %{"outcome" => outcome}) end)

        lapse = Task.async(fn -> Lapse.boot(@service, "boot_1", [fixture.attempt]) end)
        answered = Task.await(complete, 10_000)
        assert {:ok, lapsed} = Task.await(lapse, 10_000)

        # Exactly one writer's row stands. A complete that found the row
        # lapsed already is answered lost by an attempt that stops; one
        # whose write the lapse beat by less is answered as the row stands.
        case lapsed do
          [] ->
            assert %{"ok" => _output} = answered
            assert %{status: "completed"} = row(fixture)
            assert %{state: "completed", outcome: "ok"} = attempt_row(fixture)

          [%{attempt: attempt}] ->
            assert attempt == fixture.attempt
            assert match?(%{"ok" => _output}, answered) or answered == %{"error" => "lost"}
            assert %{status: "failed", error_message: @lapsed} = row(fixture)
            assert %{state: "lapsed", outcome: "uncertain"} = attempt_row(fixture)
        end

        # The attempt stops either way and its slot goes back once; a
        # repeated lapse finds nothing, and takes nothing back.
        wait_until(fn -> not Process.alive?(fixture.pid) end)
        wait_until(fn -> Slots.status(@slots).active == before end, 2_000, "the slot given back")
        assert {:ok, []} = Lapse.boot(@service, "boot_1", [fixture.attempt])

        assert :ok =
                 Attempt.stop_unclosed(fixture.attempt, %{
                   service_id: @service,
                   boot_id: "boot_1",
                   runner: nil
                 })

        assert Slots.status(@slots).active == before
      end
    end
  end

  describe "settings" do
    test "the bounds and the worker list are validated when the watch starts" do
      assert {:error, message} = WorkerWatch.start_link(workers: [], poll_ms: 0, name: :bad_watch)
      assert message =~ "poll_ms"

      assert {:error, message} = WorkerWatch.start_link(workers: [], misses: -1, name: :bad_watch)
      assert message =~ "misses"

      assert {:error, message} =
               WorkerWatch.start_link(workers: [%{id: "wrk_x"}], name: :bad_watch)

      assert message =~ "endpoint"

      twice = [
        %{id: "wrk_x", url: "http://127.0.0.1:19"},
        %{id: "wrk_x", url: "http://127.0.0.1:20"}
      ]

      assert {:error, message} = WorkerWatch.start_link(workers: twice, name: :bad_watch)
      assert message =~ "wrk_x"

      assert {:error, message} = WorkerWatch.start_link(workers: [], name: "watch")
      assert message =~ "name"

      # The application's configuration is read the same way, and the
      # defaults stand where it says nothing.
      previous = Application.get_env(:cyfr, :worker_watch)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:cyfr, :worker_watch, previous),
          else: Application.delete_env(:cyfr, :worker_watch)
      end)

      Application.put_env(:cyfr, :worker_watch, poll_ms: "5000")
      assert {:error, message} = WorkerWatch.start_link(workers: [], name: :bad_watch)
      assert message =~ "poll_ms"

      Application.put_env(:cyfr, :worker_watch, misses: 2)
      {:ok, pid} = WorkerWatch.start_link(workers: [], name: :configured_watch)
      assert %{poll_ms: 5_000, misses: 2} = :sys.get_state(pid)
      GenServer.stop(pid)
    end

    test "the application's watch is a child beside the sweeper, gated off in this environment" do
      children = Supervisor.which_children(Cyfr.InfraSupervisor)

      assert {WorkerWatch, :undefined, :worker, [WorkerWatch]} =
               List.keyfind(children, WorkerWatch, 0)

      assert :ignore = WorkerWatch.start_link([])
      assert WorkerWatch.fresh_boot(%{id: "wrk_local", url: "http://127.0.0.1:4200"}) == :unknown
    end
  end

  describe "dispatch" do
    setup do
      configured = Application.get_env(:cyfr, :workers)
      on_exit(fn -> Application.put_env(:cyfr, :workers, configured) end)
      :ok
    end

    test "addresses a start to the boot the watch heard within a poll interval, and asks otherwise" do
      endpoint = serve!([status("boot_1")])
      Application.put_env(:cyfr, :workers, [endpoint])

      # Without a watch, each selection asks the worker service.
      assert {:ok, %{service: @service, boot: "boot_1", endpoint: ^endpoint}} = Dispatch.worker()
      assert_receive {:status_asked, _answer}, 1_000

      # With one that heard the boot, none does.
      watch!(endpoint, name: WorkerWatch, poll_ms: 60_000)
      assert_receive {:status_asked, _answer}, 1_000
      wait_until(fn -> WorkerWatch.fresh_boot(endpoint) == {:ok, "boot_1"} end)
      assert {:ok, %{service: @service, boot: "boot_1"}} = Dispatch.worker()
      assert {:ok, %{boot: "boot_1"}} = Dispatch.worker("reagent:local.any")
      refute_receive {:status_asked, _answer}, 100

      # A boot heard longer ago than one poll interval is asked for again.
      :ok = stop_supervised(WorkerWatch)
      watch!(endpoint, name: WorkerWatch, poll_ms: 60)
      Arca.ControlPlane.record(:lost)
      on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)
      wait_until(fn -> WorkerWatch.fresh_boot(endpoint) == :unknown end, 1_000)
      assert {:ok, %{boot: "boot_1"}} = Dispatch.worker()
      assert_receive {:status_asked, _answer}, 1_000
    end
  end
end
