# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.AttemptSlotWaitTest do
  @moduledoc """
  A run whose row ends while it is queued for its execution slot leaves the
  queue when the row ends, and is never started.

  The runs are dispatched for real (`Crucible.Dispatch.run/4`) to the
  scripted worker service behind a gate that tells the test every `start`
  and `kill` it is asked for, with every free slot of the boot's
  `Crucible.Slots` held by the test, so a run is queued until the
  test frees one. A cancel is `Crucible.cancel/2`. What a queued task
  holds is counted at each host-side authority: the node's budget count,
  the reservation's charge rows and the execution slots.

  The cancel and the grant race in three orders, each forced by holding one
  side: the cancel whole before the grant; the grant between the cancel's
  terminal write and its stop; and the grant whole before the cancel, which
  lands while the start is on its way to the worker service. In each the
  slot goes back once, nothing of a sibling's goes with it, and no runner
  attaches to the cancelled run.

  A queued task leaves the same way when its parent's cascade ends its
  row and when its waiter is killed, and gives back what it held when it
  waits its slot wait out. An attempt whose row ended before it was asked
  for its slot does not queue. And a background root cancelled while it
  is queued under its athanor's full share leaves its place to the next
  in line.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.TwoServices, only: [root!: 3, spawn_child!: 5, spawn_child!: 6]
  import Prima.Test.Wait

  alias Crucible.{Attempt, Dispatch, Record}
  alias Prima.Slots
  alias Cyfr.Test.{AttemptFixtures, ScriptedWorker, ScriptedWorkerListener}
  alias Prima.Test.AuthorityFixtures
  alias Sanctum.Test.ConsentFixtures

  @moduletag :capture_log

  @node "reagent:local.slot-wait"
  @ref "reagent:local.slot-wait:1.0.0"
  @math_wasm Path.expand("../support/test_wasm/math.wasm", __DIR__)
  @slots Crucible.Slots
  @cancelled "Execution cancelled"
  @lapsed "Execution terminated: runner stopped without cleanup"

  # The scripted worker service behind a gate: each `start` and `kill` it
  # is asked for is told to the test first, a `start` waits at the gate
  # while it is closed, and a kill the test holds is answered only once the
  # test lets it go, the runner killed meanwhile. Served under the scripted
  # service's id, so its requests are signed and its runners attach as that
  # service's.
  defmodule Gate do
    @moduledoc false
    @behaviour Prima.WorkerAPI

    def start_link(test),
      do:
        Agent.start_link(fn -> %{test: test, closed: false, held_kills: MapSet.new()} end,
          name: __MODULE__
        )

    def close, do: Agent.update(__MODULE__, &%{&1 | closed: true})

    def open(handler) do
      Agent.update(__MODULE__, &%{&1 | closed: false})
      send(handler, :open)
    end

    # The kill of `execution_id` kills its runner and then waits, telling
    # the test `{:killed, execution_id, handler}`, until the test sends the
    # handler `:proceed`: whoever asked for the kill is held after it.
    def hold_kill(execution_id),
      do: Agent.update(__MODULE__, &%{&1 | held_kills: MapSet.put(&1.held_kills, execution_id)})

    @impl true
    def start(token, input, sealed_keys) do
      {:ok, %{execution_id: id}} = Prima.Assignment.read(token)
      %{test: test, closed: closed?} = Agent.get(__MODULE__, & &1)
      send(test, {:start, id, self()})

      if closed? do
        receive do
          :open -> :ok
        after
          30_000 -> :ok
        end
      end

      ScriptedWorker.start(token, input, sealed_keys)
    end

    @impl true
    def kill(execution_id) do
      %{test: test, held_kills: held} = Agent.get(__MODULE__, & &1)
      send(test, {:kill, execution_id})
      answer = ScriptedWorker.kill(execution_id)

      if MapSet.member?(held, execution_id) do
        send(test, {:killed, execution_id, self()})

        receive do
          :proceed -> :ok
        after
          30_000 -> :ok
        end
      end

      answer
    end

    @impl true
    def status, do: ScriptedWorker.status()
  end

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    run_dir = Path.join(System.tmp_dir!(), "slot_wait_#{System.unique_integer([:positive])}")
    keys = [arca: :base_path, cyfr: :workers]
    previous = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)
    Application.put_env(:arca, :base_path, run_dir)
    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      Slots.forgive_unreaped(@slots, ctx.athanor_id)

      for {{app, key}, value} <- previous do
        if value,
          do: Application.put_env(app, key, value),
          else: Application.delete_env(app, key)
      end

      File.rm_rf!(run_dir)
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()

    {:ok, component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@math_wasm), %{
        name: "slot-wait",
        version: "1.0.0",
        type: "reagent"
      })

    # The rate window and the unreaped notes are this boot's, not the
    # sandbox's: every run of these tests draws on them.
    ScriptedWorker.fresh_limits!(ctx, [@ref])

    {:ok, ctx: ctx, component: component}
  end

  # ---------------------------------------------------------------------------
  # A queued task
  # ---------------------------------------------------------------------------

  describe "a task queued for its execution slot" do
    setup %{ctx: ctx} do
      serve!([:hang, :hang])
      authority = AuthorityFixtures.root!()
      root = root!(ctx, authority, cap: 2)
      before = Slots.status(@slots).child_active

      # A sibling of the same root, attached and holding its slot, its
      # budget slot and its charge row throughout. Its waiter is linked to
      # the test, and ends with it.
      sibling = Prima.UUID7.execution_id()

      Task.async(fn ->
        spawn_child!(ctx, authority, root, @ref, input(), execution_id: sibling)
      end)

      assert_receive {:start, ^sibling, _handler}, 10_000
      wait_until(fn -> attached?(sibling) end, 10_000, "the sibling's runner attached")

      filler = fill_slots!()
      queued = Prima.UUID7.execution_id()

      waiter =
        Task.async(fn ->
          spawn_child!(ctx, authority, root, @ref, input(), execution_id: queued)
        end)

      wait_until(
        fn -> Slots.status(@slots).queued_by_class.child == 1 end,
        10_000,
        "a queued task"
      )

      # Admitted, charged and waiting: the sibling and the queued task each
      # hold a budget slot and a charge row, and the sibling alone a slot.
      assert %{state: "running", claimed_by: nil} = attempt(ctx, queued)
      held = %{ctx: ctx, authority: authority, children: before + filler.held}
      assert accounting(held) == expected(held, [sibling, queued], 1)

      {:ok,
       held: held,
       authority: authority,
       root: root,
       sibling: sibling,
       queued: queued,
       waiter: waiter,
       filler: filler}
    end

    test "cancelled, it gives back its budget slot and charge row at the cancel, takes no slot freed later and is never started",
         %{ctx: ctx, held: held, sibling: sibling, queued: queued, waiter: waiter, filler: filler} do
      assert {:ok, %{cancelled: true}} = Crucible.cancel(ctx, queued)

      # At the cancel, with every slot still held: nothing was granted.
      assert {{:error, @cancelled}, ^queued} = Task.await(waiter, 10_000)
      wait_until(fn -> Attempt.whereis(queued) == nil end, 10_000, "the queued attempt stopped")
      assert_accounting(held, [sibling], 1)
      assert_slots(%{available: 0, queued: 0})
      assert %{state: "cancelled", claimed_by: nil} = attempt(ctx, queued)

      # The next slot freed is nobody's.
      release_slots!(filler, 1)

      wait_until(
        fn -> Slots.status(@slots).available == 1 end,
        10_000,
        "the freed slot stayed free"
      )

      assert_accounting(%{held | children: held.children - 1}, [sibling], 1)

      # No worker service was asked anything of the cancelled run.
      refute_received {:start, ^queued, _handler}
      refute_received {:kill, ^queued}
      assert [%{execution_id: ^sibling}] = ScriptedWorker.calls()
    end

    test "cancelled twice, and stopped again, it gives back once: its sibling keeps what it holds, and one more task fits",
         %{
           ctx: ctx,
           held: held,
           authority: authority,
           root: root,
           sibling: sibling,
           queued: queued,
           waiter: waiter,
           filler: filler
         } do
      assert {:ok, %{cancelled: true}} = Crucible.cancel(ctx, queued)
      assert {{:error, @cancelled}, ^queued} = Task.await(waiter, 10_000)
      assert_accounting(held, [sibling], 1)

      # The cancel again, and the stop it ends with delivered again.
      assert {:error, :not_cancellable} = Crucible.cancel(ctx, queued)
      assert :ok = Dispatch.stop(queued, ctx.athanor_id)
      assert_accounting(held, [sibling], 1)
      assert is_pid(Attempt.whereis(sibling))

      # The root's two tasks are the sibling and one more: not one short
      # (the queued task's hold came back), not one over (the sibling's did
      # not come back with it).
      release_slots!(filler, filler.held)
      third = Prima.UUID7.execution_id()

      Task.async(fn ->
        spawn_child!(ctx, authority, root, @ref, input(), execution_id: third)
      end)

      wait_until(fn -> attached?(third) end, 10_000, "a third task's runner attached")

      assert {{:error, {:invoke_denied, :invoke_budget_exhausted}}, _refused} =
               spawn_child!(ctx, authority, root, @ref, input())

      assert_accounting(%{held | children: held.children - filler.held}, [sibling, third], 2)
    end

    test "whose row ends before the grant and whose stop comes after it gives the granted slot straight back",
         %{ctx: ctx, held: held, sibling: sibling, queued: queued, waiter: waiter, filler: filler} do
      # The cancel, held between its terminal write and its stop: the row
      # is cancelled, and the attempt has not been told.
      assert {:ok, %{status: :cancelled}} = Record.cancel(ctx, queued)
      assert %{queued: 1} = Slots.status(@slots)

      # The grant: the attempt reads its row before it answers, and the
      # slot goes back instead of starting a runner.
      release_slots!(filler, 1)
      assert {{:error, @cancelled}, ^queued} = Task.await(waiter, 10_000)
      wait_until(fn -> Attempt.whereis(queued) == nil end, 10_000, "the queued attempt stopped")

      wait_until(
        fn -> Slots.status(@slots).available == 1 end,
        10_000,
        "the granted slot came back"
      )

      assert_accounting(%{held | children: held.children - 1}, [sibling], 1)

      # The rest of the cancel finds nothing to stop and releases nothing.
      assert :ok = Dispatch.stop(queued, ctx.athanor_id)
      assert_accounting(%{held | children: held.children - 1}, [sibling], 1)
      assert_slots(%{available: 1, queued: 0})

      refute_received {:start, ^queued, _handler}
      assert [%{execution_id: ^sibling}] = ScriptedWorker.calls()
    end

    test "granted its slot and cancelled while its start is on its way gives the slot back once, and its runner's attach is refused",
         %{ctx: ctx, held: held, sibling: sibling, queued: queued, waiter: waiter, filler: filler} do
      # The grant first: the row is live, so the start sets off, and is held
      # at the worker service's door.
      Gate.close()
      release_slots!(filler, 1)
      assert_receive {:start, ^queued, handler}, 10_000
      held = %{held | children: held.children - 1}
      assert_accounting(held, [sibling, queued], 2)

      # The cancel lands on an attempt that holds its slot and has no
      # runner yet: it gives back what the run held, once. The run is
      # dispatched by now, so the cancel asks for its runner's kill, which
      # finds none.
      assert {:ok, %{cancelled: true}} = Crucible.cancel(ctx, queued)
      assert_received {:kill, ^queued}

      wait_until(
        fn -> Attempt.whereis(queued) == nil end,
        10_000,
        "the cancelled attempt stopped"
      )

      assert_accounting(held, [sibling], 1)
      assert_slots(%{available: 1})

      # The start arrives after all. The row refuses its runner's claim, so
      # no runner attaches, and the waiter answers the row and has the
      # runner killed.
      Gate.open(handler)
      assert {{:error, @cancelled}, ^queued} = Task.await(waiter, 10_000)
      assert_receive {:kill, ^queued}, 10_000

      wait_until(
        fn -> match?({:ok, %{attempts: [_sibling]}}, ScriptedWorker.status()) end,
        10_000
      )

      assert [%{execution_id: ^sibling}] = ScriptedWorker.calls()
      assert %{state: "cancelled", claimed_by: nil} = attempt(ctx, queued)
      assert_accounting(held, [sibling], 1)
      assert_slots(%{available: 1, queued: 0})
    end

    test "whose parent is cancelled leaves the queue with the cascade, and takes no slot the kill of its sibling's runner frees",
         %{ctx: ctx, held: held, root: root, sibling: sibling, queued: queued, waiter: waiter} do
      ended = "Parent execution (#{root.id}) terminated"

      # The cascade is held right after it kills the sibling's runner, until
      # the slot that kill frees has been offered to the queued task: in
      # whichever order the cascade reaches the two, the queued task is
      # offered a slot while the cascade is still under way.
      Gate.hold_kill(sibling)
      canceller = Task.async(fn -> Crucible.cancel(ctx, root.id) end)
      assert_receive {:killed, ^sibling, handler}, 10_000

      wait_until(
        fn -> Attempt.whereis(sibling) == nil and Slots.status(@slots).queued == 0 end,
        10_000,
        "the slot the sibling's kill freed offered to the queued task"
      )

      send(handler, :proceed)
      assert {:ok, %{cancelled: true}} = Task.await(canceller, 10_000)

      # Its row had ended by then: the slot went back, and no runner was
      # started for it.
      assert {{:error, ^ended}, ^queued} = Task.await(waiter, 10_000)
      wait_until(fn -> Attempt.whereis(queued) == nil end, 10_000, "the queued attempt stopped")
      assert %{state: "failed", claimed_by: nil} = attempt(ctx, queued)
      assert_accounting(held, [], 0)
      assert_slots(%{available: 1, queued: 0})

      # Only the task that had a runner had it killed.
      assert_received {:kill, ^sibling}
      refute_received {:start, ^queued, _handler}
      refute_received {:kill, ^queued}
    end

    test "whose waiter is killed gives back at the kill, with no slot freed",
         %{ctx: ctx, held: held, sibling: sibling, queued: queued, waiter: waiter} do
      assert Task.shutdown(waiter, :brutal_kill) == nil

      wait_until(fn -> Attempt.whereis(queued) == nil end, 10_000, "the queued attempt stopped")
      assert_accounting(held, [sibling], 1)
      assert_slots(%{available: 0, queued: 0})
      assert %{state: "lapsed", claimed_by: nil} = attempt(ctx, queued)

      assert %{status: "failed", error_message: @lapsed} =
               Arca.Repo.get!(Arca.Schemas.Execution, queued)

      refute_received {:start, ^queued, _handler}
      refute_received {:kill, ^queued}
    end

    test "that waits out its slot is closed failed and gives back what it held",
         %{
           ctx: ctx,
           held: held,
           authority: authority,
           root: root,
           sibling: sibling,
           queued: queued,
           waiter: waiter
         } do
      # The cancelled task makes room under the root's cap for a task
      # whose slot wait is a second long, which it waits out.
      assert {:ok, %{cancelled: true}} = Crucible.cancel(ctx, queued)
      assert {{:error, @cancelled}, ^queued} = Task.await(waiter, 10_000)

      timed_out = Prima.UUID7.execution_id()
      assert {:error, refusal} = spawn_within(ctx, authority, root, timed_out, 1_000)
      assert refusal == Slots.refusal(:timeout)

      wait_until(
        fn -> Attempt.whereis(timed_out) == nil end,
        10_000,
        "the timed-out attempt stopped"
      )

      assert %{state: "failed", claimed_by: nil} = attempt(ctx, timed_out)
      assert_accounting(held, [sibling], 1)
      assert_slots(%{available: 0, queued: 0})
      refute_received {:start, ^timed_out, _handler}
    end
  end

  # ---------------------------------------------------------------------------
  # A row that ended first
  # ---------------------------------------------------------------------------

  describe "an attempt whose row ended before it was asked for its slot" do
    test "does not wait for one: no stop found it, so it reads its row", %{ctx: ctx} do
      # A row ended before its attempt was registered is told to nobody:
      # the terminal write alone, as a parent's cascade lands when its
      # child's admission commits.
      fixture = AttemptFixtures.attached!(ctx: ctx, attach: false)
      assert {:ok, %{status: :cancelled}} = Record.cancel(ctx, fixture.execution_id)
      assert Process.alive?(fixture.pid)

      # With no slot free, and a slot wait far longer than the answer is
      # given to come: it is answered without queueing.
      fill_slots!()
      watch = Process.monitor(fixture.pid)
      asked = Task.async(fn -> Attempt.take_slot(fixture.pid, :child, 60_000) end)
      assert Task.await(asked, 10_000) == :closed
      assert_receive {:DOWN, ^watch, :process, _pid, :normal}, 5_000
      assert_slots(%{available: 0, queued: 0})
    end
  end

  # ---------------------------------------------------------------------------
  # A queued root
  # ---------------------------------------------------------------------------

  describe "a background root queued under its athanor's full share" do
    setup %{ctx: ctx, component: component} do
      answer = %{"content" => [%{"type" => "text", "text" => "ran"}]}
      serve!([answer])
      consent!(ctx, component)
      :ok
    end

    test "cancelled, it frees its place: the next waiter of the athanor takes the share freed next",
         %{ctx: ctx} do
      # Background work stops at half the athanor's cap: with that half
      # held, the athanor's background roots queue in order.
      share = Slots.background_ceiling(Slots.status(@slots).key_max)
      holders = for _ <- 1..share, do: hold!(ctx.athanor_id, :background)

      first = Prima.UUID7.execution_id()
      first_task = Task.async(fn -> background(ctx, first) end)
      wait_until(fn -> Slots.status(@slots).queued_by_class.background == 1 end, 10_000)

      second = Prima.UUID7.execution_id()
      second_task = Task.async(fn -> background(ctx, second) end)
      wait_until(fn -> Slots.status(@slots).queued_by_class.background == 2 end, 10_000)

      # The first in line is cancelled: it leaves the queue at the cancel.
      assert {:ok, %{cancelled: true}} = Crucible.cancel(ctx, first)
      assert {:error, @cancelled} = Task.await(first_task, 10_000)
      wait_until(fn -> Slots.status(@slots).queued_by_class.background == 1 end, 10_000)

      # One share freed is the second's: it runs to its end.
      send(hd(holders), :release)
      assert {:ok, %{status: :completed}} = Task.await(second_task, 30_000)

      assert_receive {:start, ^second, _handler}
      refute_received {:start, ^first, _handler}
      refute_received {:kill, ^first}
      assert [%{execution_id: ^second}] = ScriptedWorker.calls()

      Enum.each(tl(holders), &send(&1, :release))

      wait_until(
        fn -> Map.get(Slots.status(@slots).keys, ctx.athanor_id, 0) == 0 end,
        10_000,
        "the athanor's share came back"
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Work
  # ---------------------------------------------------------------------------

  defp input, do: %{"messages" => []}

  # The scripted service, reached through the gate.
  defp serve!(script) do
    start_supervised!({ScriptedWorker, ref: @node, script: script})
    start_supervised!(%{id: Gate, start: {Gate, :start_link, [self()]}})

    listener =
      start_supervised!({ScriptedWorkerListener, worker: Gate, service: ScriptedWorker.service()})

    gate = ScriptedWorkerListener.url(listener)
    scripted = ScriptedWorker.service()

    Application.put_env(
      :cyfr,
      :workers,
      Enum.map(Application.get_env(:cyfr, :workers), fn
        %{id: ^scripted} = entry -> %{entry | url: gate}
        entry -> entry
      end)
    )
  end

  # A task of `root` whose parent's deadline leaves it `ms`, and so a slot
  # wait as long.
  defp spawn_within(ctx, authority, root, id, ms) do
    Crucible.run_child(authority, @ref, nil, input(),
      ctx: ctx,
      execution_id: id,
      parent_execution_id: root.id,
      root_execution_id: root.id,
      declared_needs: [],
      retention_class: "chat_step",
      charge: %{
        id: "call:t:1:c#{System.unique_integer([:positive])}:g0",
        attempt: root.attempt,
        generation: 0,
        holder_execution_id: id
      },
      guest_fn: :spawn,
      parent_deadline: System.system_time(:millisecond) + ms
    )
  end

  defp attached?(id), do: Enum.any?(ScriptedWorker.calls(), &(&1.execution_id == id))

  defp background(ctx, id) do
    Crucible.run_root(ctx, :default, @ref, input(),
      execution_id: id,
      class: :background
    )
  end

  # An owner profile whose consent admits the node at ingress.
  defp consent!(ctx, component) do
    profile = %{
      id: "prof-slot-wait",
      kind: :owner,
      source_ref: @node,
      label: "default",
      status: :active
    }

    :ok =
      ConsentFixtures.seed_head!(ctx, profile, %{
        id: "consent-slot-wait",
        revision: 1,
        scope: :versionless,
        pinned_version: "",
        invoke_mode: :open_inert,
        shape_digest: "sha256:shape-slot-wait",
        commit_digest: "sha256:commit-slot-wait",
        resolved_policy:
          Jason.encode!(%{
            "canonical" => "jcs-1",
            "nodes" => %{
              @node => %{
                "limits" => %{
                  "timeout" => "1m",
                  "max_memory_bytes" => 67_108_864,
                  "max_request_size" => 1_048_576,
                  "max_response_size" => 5_242_880,
                  "rate_limit" => %{"requests" => 100, "window" => "1m"},
                  "max_concurrent_tasks" => 5,
                  "batch_timeout" => "1m"
                },
                "edges" => %{"@ingress" => %{}}
              }
            }
          }),
        activation: %{@node => component.release_digest},
        vault_refs: []
      })
  end

  # ---------------------------------------------------------------------------
  # The accounting
  # ---------------------------------------------------------------------------

  # What each host-side authority counts for the root: the node's budget
  # count, the reservation's count and its charge rows by the task that
  # holds each, and the children's execution slots.
  defp accounting(%{ctx: ctx, authority: authority}) do
    budget = authority.budget.id
    {:ok, charges} = Arca.BudgetReservations.charges(Sanctum.Context.actor(ctx), budget)

    %{
      in_flight: Sanctum.Authority.budget(authority).in_flight,
      charged: Arca.BudgetReservations.lookup(Sanctum.Context.actor(ctx), budget).charged,
      charges: charges |> Enum.map(& &1.holder_execution_id) |> Enum.sort(),
      child_slots: Slots.status(@slots).child_active
    }
  end

  # `tasks` each hold a budget slot and a charge row, and `slots` of them an
  # execution slot, beside the `children` slots held otherwise.
  defp expected(%{children: children}, tasks, slots) do
    %{
      in_flight: length(tasks),
      charged: length(tasks),
      charges: Enum.sort(tasks),
      child_slots: children + slots
    }
  end

  # A stopping attempt gives back what it held after its waiter has its
  # answer, so the accounting is polled, and then asserted so a failure
  # shows what it was.
  defp assert_accounting(held, tasks, slots) do
    expected = expected(held, tasks, slots)

    try do
      wait_until(fn -> accounting(held) == expected end, 10_000)
    rescue
      ExUnit.AssertionError -> :ok
    end

    assert accounting(held) == expected
  end

  # The slots hear of a holder's end after its attempt has stopped, so their
  # counts are polled too.
  defp assert_slots(expected) do
    counts = fn -> Map.take(Slots.status(@slots), Map.keys(expected)) end

    try do
      wait_until(fn -> counts.() == expected end, 10_000)
    rescue
      ExUnit.AssertionError -> :ok
    end

    assert counts.() == expected
  end

  defp attempt(ctx, id), do: Arca.ExecutionAttempts.current(Sanctum.Context.actor(ctx), id)

  # Every free execution slot, held by one process until `release_slots!/2`
  # gives it back or the test ends.
  defp fill_slots! do
    free = Slots.status(@slots).available

    {:ok, holder} =
      Agent.start_link(fn ->
        for _ <- 1..free//1 do
          {:ok, ref} = Slots.acquire(@slots, nil, :child, wait_ms: 0)
          ref
        end
      end)

    on_exit(fn -> if Process.alive?(holder), do: Agent.stop(holder) end)
    assert Slots.status(@slots).available == 0
    %{holder: holder, held: free}
  end

  defp release_slots!(%{holder: holder}, count) do
    Agent.update(holder, fn refs ->
      {released, kept} = Enum.split(refs, count)
      Enum.each(released, &Slots.release(@slots, &1))
      kept
    end)
  end

  # A process holding one slot of `class` for `key` until told to release,
  # linked so a failing test takes it down.
  defp hold!(key, class) do
    test = self()

    pid =
      spawn_link(fn ->
        {:ok, ref} = Slots.acquire(@slots, key, class, wait_ms: 0)
        send(test, {:holding, self()})

        receive do
          :release -> Slots.release(@slots, ref)
        end
      end)

    assert_receive {:holding, ^pid}, 5_000
    pid
  end
end
