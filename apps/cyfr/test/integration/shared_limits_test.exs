# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.SharedLimitsTest do
  @moduledoc """
  One consent's limits hold across two worker services. The step stub's
  consent allows 10 invocations a minute and 2 concurrent tasks, and its
  runs are split between the Opus service, which runs the stub for real,
  and the scripted service, each reached over HTTP: ten invocations are
  admitted between them and the eleventh is refused whichever service it
  was headed for, and two tasks held open, one on each, are the consent's
  two, a third refused on either.

  Each limit has one authority, on the host: the rate is admission's
  (`Cyfr.Execution.Rates`), the task cap is the root's budget
  (`Sanctum.Authority`) made durable by its reservation
  (`Arca.BudgetReservations`), and the execution slot is
  `Cyfr.Execution.Slots`'. A worker service counts nothing that admits.
  What a task held goes back once, and only what it held: when it is
  cancelled, or its waiter is killed, while it waits for a slot, each at
  that moment and with no slot taken; when the service running it dies;
  and when its completion, its cancel and its runner's exit report are each
  delivered twice. After each, the tasks the consent still admits are
  counted: neither one short nor one over.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.TwoServices
  import Cyfr.Test.Wait

  alias Cyfr.Authority
  alias Cyfr.Execution.{Attempt, Keys, Rates, Sweeper}
  alias Cyfr.Slots
  alias Cyfr.Test.{OpusService, ScriptedWorker}
  alias Cyfr.Test.TwoServices.Wire
  alias Cyfr.{WorkerAuth, WorkerWire}
  alias Sanctum.Consent.{Bootstrap}

  @moduletag timeout: 180_000
  @moduletag :capture_log

  @stub stub()
  @stub_ref "#{stub()}:#{version()}"
  @slots Cyfr.Execution.Slots
  @rate %{requests: 10, window: "1m"}
  @tasks 2
  @lapsed "Execution terminated: runner stopped without cleanup"
  @local OpusService.service()
  @other ScriptedWorker.service()

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    run_dir = Path.join(System.tmp_dir!(), "shared_limits_#{System.unique_integer([:positive])}")
    keys = [arca: :base_path, arca: :seed_path, cyfr: :workers]
    previous = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)
    Application.put_env(:arca, :base_path, Path.join(run_dir, "data"))

    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      fresh_limits!(ctx)

      for {{app, key}, value} <- previous do
        if value,
          do: Application.put_env(app, key, value),
          else: Application.delete_env(app, key)
      end

      File.rm_rf!(run_dir)
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()

    # The consent: what the stub's manifest asks for is what is minted.
    seed =
      lay_seed!(Path.join(run_dir, "seed"),
        limits: %{
          "rate_limit" => %{"requests" => @rate.requests, "window" => @rate.window},
          "max_concurrent_tasks" => @tasks
        }
      )

    Application.put_env(:arca, :seed_path, seed)
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @stub in minted
    arm!(ctx, key: "k-#{System.unique_integer([:positive])}", token: "t-unused")

    {:ok, authority} = Cyfr.Execution.authority_for(ctx, :default, @stub)
    assert %{rate_limit: @rate, max_concurrent_tasks: @tasks} = Authority.limits(authority)
    assert authority.budget.cap == @tasks

    # The rate window and the unreaped notes are this boot's, not the
    # sandbox's: every test of the athanor draws on them.
    fresh_limits!(ctx)

    {:ok, ctx: ctx, authority: authority}
  end

  # ---------------------------------------------------------------------------
  # The rate
  # ---------------------------------------------------------------------------

  test "ten invocations a minute are ten across both services, and the eleventh is refused on either",
       %{ctx: ctx} do
    answers = for n <- 1..5, do: %{"content" => [%{"type" => "text", "text" => "scripted #{n}"}]}
    start_supervised!({ScriptedWorker, ref: @stub, script: answers})

    admitted =
      for n <- 1..@rate.requests do
        service = if rem(n, 2) == 1, do: @local, else: @other
        id = Cyfr.UUID7.execution_id()
        route!(service)
        assert {:ok, %{status: :completed}} = invoke(ctx, id)
        assert %{state: "completed", service_id: ^service} = attempt(ctx, id)
        {service, id}
      end

    # Five ran on each, and the window is full.
    assert %{@local => 5, @other => 5} = Enum.frequencies_by(admitted, &elem(&1, 0))
    assert length(ScriptedWorker.calls()) == 5

    assert {:ok, 10, 0, _window_ms} =
             Rates.status(Sanctum.Context.actor(ctx), @stub_ref, %{rate_limit: @rate})

    # A refused invocation is recorded failed, and no runner claims it.
    for service <- [@local, @other] do
      id = Cyfr.UUID7.execution_id()
      route!(service)
      assert {:error, "Rate limit exceeded. Retry in " <> _} = invoke(ctx, id)
      assert %{state: "failed", service_id: ^service, claimed_by: nil} = attempt(ctx, id)
    end

    # Neither service was asked to run a refused invocation.
    assert length(ScriptedWorker.calls()) == 5
    assert {:ok, %{attempts: []}} = ScriptedWorker.status()
    wait_until(fn -> OpusService.status().attempts == [] end, 10_000)

    assert {:ok, 10, 0, _window_ms} =
             Rates.status(Sanctum.Context.actor(ctx), @stub_ref, %{rate_limit: @rate})
  end

  # ---------------------------------------------------------------------------
  # The task cap
  # ---------------------------------------------------------------------------

  test "two tasks held open, one on each service, are the consent's two: a third is refused on either",
       %{ctx: ctx, authority: authority} do
    start_supervised!({ScriptedWorker, ref: @stub, script: [:hang]})
    before = Slots.status(@slots).child_active
    root = root!(ctx, authority)

    on_opus = hold_on_opus!(ctx, authority, root)
    on_scripted = hold_on_scripted!(ctx, authority, root)
    assert_held(ctx, authority, [on_opus, on_scripted], before)

    # Each service holds one of the two.
    assert %{attempts: [_one]} = OpusService.status()
    assert {:ok, %{attempts: [_one]}} = ScriptedWorker.status()

    for service <- [@local, @other] do
      route!(service)

      assert {{:error, {:invoke_denied, :invoke_budget_exhausted}}, refused} =
               spawn!(ctx, authority, root)

      assert attempt(ctx, refused) == nil
    end

    # The reservation, asked without the node's count, is as full.
    assert :exhausted =
             Arca.BudgetReservations.charge(
               Sanctum.Context.actor(ctx),
               authority.budget.id,
               %{id: "probe", attempt: root.attempt, generation: 0, holder_execution_id: nil},
               1
             )

    assert_held(ctx, authority, [on_opus, on_scripted], before)
    assert length(ScriptedWorker.calls()) == 1

    finish!(on_opus)
    cancel!(ctx, on_scripted)
    assert_held(ctx, authority, [], before)
  end

  # ---------------------------------------------------------------------------
  # Giving back
  # ---------------------------------------------------------------------------

  test "a task cancelled while it waits for a slot leaves the wait: it gives back at the cancel, takes no slot and is never started",
       %{ctx: ctx, authority: authority} do
    start_supervised!({ScriptedWorker, ref: @stub, script: [:hang]})
    wire = Wire.start!(ScriptedWorker.url())
    before = Slots.status(@slots).child_active
    root = root!(ctx, authority)

    on_opus = hold_on_opus!(ctx, authority, root)
    filler = fill_slots!()

    # Admitted, charged and waiting: no slot is free for its attempt. What
    # CYFR asks of the scripted service crosses the wire, which keeps it.
    route!(@other)
    through!(wire)
    queued = Cyfr.UUID7.execution_id()
    waiter = Task.async(fn -> spawn!(ctx, authority, root, queued) end)

    wait_until(
      fn -> Slots.status(@slots).queued_by_class.child == 1 end,
      10_000,
      "a queued child"
    )

    assert %{state: "running", service_id: @other, claimed_by: nil} = attempt(ctx, queued)
    assert %{in_flight: 2, charged: 2} = accounting(ctx, authority)

    # Cancelled as any run is. At the cancel, with every slot still held,
    # its waiter has the row's answer and the task holds nothing.
    assert {:ok, %{cancelled: true}} = Cyfr.Execution.cancel(ctx, queued)
    assert {{:error, "Execution cancelled"}, ^queued} = Task.await(waiter, 10_000)
    wait_until(fn -> Attempt.whereis(queued) == nil end, 10_000, "the queued attempt stopped")
    assert %{state: "cancelled", claimed_by: nil} = attempt(ctx, queued)
    assert_held(ctx, authority, [on_opus], before + filler.held)
    assert_slots(%{available: 0, queued: 0})

    # The cancel again gives nothing back again, and the next slot freed
    # is nobody's: the other task's slot, and every slot the filler still
    # holds, is held.
    assert {:error, :not_cancellable} = Cyfr.Execution.cancel(ctx, queued)
    release_slots!(filler, 1)

    wait_until(
      fn -> Slots.status(@slots).available == 1 end,
      10_000,
      "the freed slot stayed free"
    )

    assert_held(ctx, authority, [on_opus], before + filler.held - 1)
    assert_slots(%{available: 1, queued: 0})

    # The scripted service was asked neither to start the task nor to kill
    # a runner it never had.
    assert Wire.seen(wire, WorkerWire.worker_route(:start)) == []
    assert Wire.seen(wire, WorkerWire.worker_route(:kill)) == []
    assert ScriptedWorker.calls() == []

    release_slots!(filler, filler.held - 1)
    assert_held(ctx, authority, [on_opus], before)

    # One more fits, and only one.
    on_scripted = hold_on_scripted!(ctx, authority, root)

    assert {{:error, {:invoke_denied, :invoke_budget_exhausted}}, _refused} =
             spawn!(ctx, authority, root)

    assert_held(ctx, authority, [on_opus, on_scripted], before)

    finish!(on_opus)
    cancel!(ctx, on_scripted)
    assert_held(ctx, authority, [], before)
  end

  test "a task whose waiter is killed while it waits for a slot gives back at the kill, and nobody else's slot",
       %{ctx: ctx, authority: authority} do
    start_supervised!({ScriptedWorker, ref: @stub, script: [:hang]})
    before = Slots.status(@slots).child_active
    root = root!(ctx, authority)

    on_opus = hold_on_opus!(ctx, authority, root)
    filler = fill_slots!()

    # Admitted, charged and waiting: no slot is free for its attempt.
    route!(@other)
    queued = Cyfr.UUID7.execution_id()
    waiter = Task.async(fn -> spawn!(ctx, authority, root, queued) end)

    wait_until(
      fn -> Slots.status(@slots).queued_by_class.child == 1 end,
      10_000,
      "a queued child"
    )

    assert %{state: "running", service_id: @other, claimed_by: nil} = attempt(ctx, queued)
    assert %{in_flight: 2, charged: 2} = accounting(ctx, authority)

    # Cancelled as a turn cancels a task: its waiter is killed. The task
    # gives back what it held at the kill, with every slot still held.
    assert Task.shutdown(waiter, :brutal_kill) == nil
    wait_until(fn -> Attempt.whereis(queued) == nil end, 10_000, "the queued attempt stopped")
    assert %{state: "lapsed", claimed_by: nil} = attempt(ctx, queued)
    assert_held(ctx, authority, [on_opus], before + filler.held)
    assert_slots(%{available: 0, queued: 0})

    # The next slot freed is nobody's: the other task's slot, and every
    # slot the filler still holds, is held.
    release_slots!(filler, 1)

    wait_until(
      fn -> Slots.status(@slots).available == 1 end,
      10_000,
      "the freed slot stayed free"
    )

    assert_held(ctx, authority, [on_opus], before + filler.held - 1)
    assert_slots(%{available: 1, queued: 0})
    assert ScriptedWorker.calls() == []
    assert ScriptedWorker.kills() == []

    release_slots!(filler, filler.held - 1)
    assert_held(ctx, authority, [on_opus], before)

    # One more fits, and only one.
    on_scripted = hold_on_scripted!(ctx, authority, root)

    assert {{:error, {:invoke_denied, :invoke_budget_exhausted}}, _refused} =
             spawn!(ctx, authority, root)

    assert_held(ctx, authority, [on_opus, on_scripted], before)

    finish!(on_opus)
    cancel!(ctx, on_scripted)
    assert_held(ctx, authority, [], before)
  end

  test "a service's death gives back what its attempts held, and nothing of the other's",
       %{ctx: ctx, authority: authority} do
    start_supervised!({ScriptedWorker, ref: @stub, script: [{:probe, self()}, :hang]})
    before = Slots.status(@slots).child_active
    root = root!(ctx, authority)

    on_opus = hold_on_opus!(ctx, authority, root)
    on_scripted = hold_on_scripted!(ctx, authority, root)
    scripted_id = on_scripted.id
    assert_receive {:scripted_probe, runner, ^scripted_id}, 10_000

    # The Opus service dies and comes back another boot. Nothing reports its
    # runner: the attempt's lease lapses, and the sweep ends the task.
    old_boot = OpusService.boot()
    refute OpusService.restart!() == old_boot
    assert %{state: "running", attempt: lapsing} = attempt(ctx, on_opus.id)
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    assert {:ok, ^past} =
             Arca.ExecutionAttempts.renew(lapsing, past, Cyfr.Test.AttemptFixtures.stored())

    :ok = Sweeper.sweep()

    assert {{:error, @lapsed}, _id} = Task.await(on_opus.task, 30_000)
    assert %{state: "lapsed", boot_id: ^old_boot} = attempt(ctx, on_opus.id)
    assert_held(ctx, authority, [on_scripted], before)

    # One more fits, and only one: on the Opus service's new boot.
    again = hold_on_opus!(ctx, authority, root)

    assert {{:error, {:invoke_denied, :invoke_budget_exhausted}}, _refused} =
             spawn!(ctx, authority, root)

    assert_held(ctx, authority, [on_scripted, again], before)

    # The scripted service's runner dies, and its service reports the exit.
    Process.exit(runner, :kill)
    assert {{:error, @lapsed}, _id} = Task.await(on_scripted.task, 30_000)
    assert %{state: "lapsed", service_id: @other} = attempt(ctx, on_scripted.id)
    assert_held(ctx, authority, [again], before)

    finish!(again)
    assert_held(ctx, authority, [], before)
  end

  test "a completion, a cancel and an exit report delivered twice each give back once",
       %{ctx: ctx, authority: authority} do
    start_supervised!({ScriptedWorker, ref: @stub, script: [:hang, :hang]})
    before = Slots.status(@slots).child_active
    root = root!(ctx, authority)

    on_opus = hold_on_opus!(ctx, authority, root)
    on_scripted = hold_on_scripted!(ctx, authority, root)
    assert_held(ctx, authority, [on_opus, on_scripted], before)

    # The completion's answer is lost once CYFR has recorded it, so the
    # Opus service's runner sends it again.
    plan!(:complete, [:forward_then_drop])
    finish!(on_opus)
    wait_until(fn -> seen(:complete) == [:forward_then_drop, :forward] end)
    assert_held(ctx, authority, [on_scripted], before)

    # One more fits, and only one.
    again = hold_on_opus!(ctx, authority, root)

    assert {{:error, {:invoke_denied, :invoke_budget_exhausted}}, _refused} =
             spawn!(ctx, authority, root)

    assert_held(ctx, authority, [on_scripted, again], before)

    # The cancel is asked twice, and the exit report its kill brought is
    # delivered again.
    %{attempt: cancelled, claimed_by: runner, boot_id: boot} = attempt(ctx, on_scripted.id)
    cancel!(ctx, on_scripted)
    assert {:error, :not_cancellable} = Cyfr.Execution.cancel(ctx, on_scripted.id)
    assert {200, %{"ok" => true}} = exit_report(@other, boot, runner, [cancelled])
    assert_held(ctx, authority, [again], before)

    # One more fits, and only one.
    route!(@other)
    last = hold_on_scripted!(ctx, authority, root)

    assert {{:error, {:invoke_denied, :invoke_budget_exhausted}}, _refused} =
             spawn!(ctx, authority, root)

    assert_held(ctx, authority, [again, last], before)

    finish!(again)
    cancel!(ctx, last)
    assert_held(ctx, authority, [], before)
  end

  # ---------------------------------------------------------------------------
  # Work
  # ---------------------------------------------------------------------------

  defp chat, do: %{"operation" => "chat", "params" => %{}}

  # One invocation of the consented node, as an external caller makes it.
  defp invoke(ctx, id),
    do: Cyfr.Execution.run_root(ctx, :default, @stub, chat(), execution_id: id)

  # One task of `root`: the stub again, under the authority it runs under.
  defp spawn!(ctx, authority, root, id \\ Cyfr.UUID7.execution_id()),
    do: spawn_child!(ctx, authority, root, @stub_ref, chat(), execution_id: id)

  defp route!(@local), do: route!(:opus, @stub)
  defp route!(@other), do: route!(:scripted, @stub)

  # Reach the scripted service through `wire` until the runs are routed
  # again.
  defp through!(wire) do
    Application.put_env(
      :cyfr,
      :workers,
      Enum.map(Application.get_env(:cyfr, :workers), fn
        %{id: @other} = entry -> %{entry | url: wire.url}
        entry -> entry
      end)
    )
  end

  # A task the Opus service runs, held at the first delta its guest
  # pushes: attached, its guest run, nothing of it written yet.
  defp hold_on_opus!(ctx, authority, root) do
    id = Cyfr.UUID7.execution_id()
    hold!(:push_deltas, id, once: true)
    route!(@local)
    task = Task.async(fn -> spawn!(ctx, authority, root, id) end)
    assert_receive {:held, ^id, guest}, 30_000
    assert %{state: "running", service_id: @local} = attempt(ctx, id)
    %{id: id, task: task, guest: guest}
  end

  # A task the scripted service runs, which never answers.
  defp hold_on_scripted!(ctx, authority, root) do
    id = Cyfr.UUID7.execution_id()
    route!(@other)
    task = Task.async(fn -> spawn!(ctx, authority, root, id) end)

    wait_until(
      fn -> Enum.any?(ScriptedWorker.calls(), &(&1.execution_id == id)) end,
      30_000,
      "the scripted runner of #{id} attached"
    )

    assert %{state: "running", service_id: @other} = attempt(ctx, id)
    %{id: id, task: task}
  end

  # Let a task held on the Opus service run to its end.
  defp finish!(%{id: id, task: task, guest: guest}) do
    release!(guest)
    assert {{:ok, %{status: :completed}}, ^id} = Task.await(task, 60_000)
  end

  # Cancel a task held on the scripted service: its runner is killed, and
  # its service's report of the exit stops its attempt.
  defp cancel!(ctx, %{id: id, task: task}) do
    assert {:ok, %{cancelled: true}} = Cyfr.Execution.cancel(ctx, id)
    assert {{:error, _cancelled}, ^id} = Task.await(task, 30_000)
    wait_until(fn -> Attempt.whereis(id) == nil end, 10_000, "the attempt of #{id} stopped")
  end

  # ---------------------------------------------------------------------------
  # The accounting
  # ---------------------------------------------------------------------------

  # Exactly `tasks` hold: a slot of the root's budget, a charge row in its
  # reservation and a child's execution slot each, beside the `children`
  # slots held before, and each is still running. A stopping attempt gives
  # back what it held after its waiter has its answer, so the accounting is
  # polled, and then asserted so a failure shows what it was.
  defp assert_held(ctx, authority, tasks, children) do
    expected = %{
      in_flight: length(tasks),
      charged: length(tasks),
      charges: tasks |> Enum.map(& &1.id) |> Enum.sort(),
      child_slots: children + length(tasks)
    }

    try do
      wait_until(fn -> accounting(ctx, authority) == expected end, 10_000)
    rescue
      ExUnit.AssertionError -> :ok
    end

    assert accounting(ctx, authority) == expected

    for %{id: id} <- tasks do
      assert is_pid(Attempt.whereis(id))
      assert %{state: "running"} = attempt(ctx, id)
    end
  end

  # What each host-side authority counts for the root: the node's budget
  # count, the reservation's count and its charge rows by the task that
  # holds each, and the children's execution slots.
  defp accounting(ctx, authority) do
    budget = authority.budget.id
    {:ok, charges} = Arca.BudgetReservations.charges(Sanctum.Context.actor(ctx), budget)

    %{
      in_flight: Sanctum.Authority.budget(authority).in_flight,
      charged: Arca.BudgetReservations.lookup(Sanctum.Context.actor(ctx), budget).charged,
      charges: charges |> Enum.map(& &1.holder_execution_id) |> Enum.sort(),
      child_slots: Slots.status(@slots).child_active
    }
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

  defp fresh_limits!(ctx) do
    for bucket <- [@stub_ref, "oauth:" <> @stub_ref],
        do: :ok = Rates.reset(Sanctum.Context.actor(ctx), bucket)

    Slots.forgive_unreaped(@slots, ctx.athanor_id)
  end

  # ---------------------------------------------------------------------------
  # The wire, by hand
  # ---------------------------------------------------------------------------

  # A runner exit report to the host listener, signed as `service` signs
  # it for its `boot`, naming this member, `runner` and `attempts`.
  defp exit_report(service, boot, runner, attempts) do
    body =
      Jason.encode!(%{
        "op" => "runner_exited",
        "args" => %{
          "member" => Keys.member(),
          "runner" => runner,
          "attempts" => attempts
        }
      })

    fields = %{
      service: service,
      boot: boot,
      ts: System.system_time(:millisecond),
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    }

    {:ok, worker_key} = Keys.worker_key(service)
    {:ok, header} = WorkerAuth.report_header(WorkerAuth.dispatch_key(worker_key), fields, body)

    {:ok, %Req.Response{status: status, body: answer}} =
      Req.post(OpusService.host_url() <> WorkerWire.host_route(:runner_exited),
        headers: [{WorkerWire.auth_header(), header}, {"content-type", "application/json"}],
        body: body,
        retry: false,
        decode_body: false
      )

    {status, Jason.decode!(answer)}
  end
end
