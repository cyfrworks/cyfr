# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.RunnerProcessEventsTest do
  @moduledoc """
  A runner's operator events are its word, and its handle
  (`Locus.Runtime.RunnerProcess`) forwards one only for what the runner
  holds: an event every execution of which is of the subtree it holds
  now, its root and each child it named, or of the one it held last, so a
  run's final events reach the forwarder on either side of its
  `complete`, and an event naming no execution only while it holds a
  subtree; any other event, and every event of a runner that has held
  nothing, is dropped. Each runner's events draw on a budget of their own
  (`Prima.RunnerControl.event_burst/0`, regaining
  `Prima.RunnerControl.events_per_second/0` a second on the handle's
  clock, which the test moves), and past it are dropped. What is dropped
  is counted: the first drop is said as it happens, and the count as a
  subtree begins and ends, and as the handle ends. The test is the
  runner, over a scripted keeper, and the forwarder too.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Locus.Runtime.RunnerProcess
  alias Locus.Runtime.Test.{ScriptedHost, ScriptedKeeper}
  alias Prima.RunnerControl

  @burst RunnerControl.event_burst()
  @per_second RunnerControl.events_per_second()

  setup do
    host = ScriptedHost.start!()
    keeper = ScriptedKeeper.start!(__MODULE__.Keeper)
    spec = %{runner: "run_events", argv: ["runner"], env: %{"KEEPER" => Atom.to_string(keeper)}}
    # The clock the handle's budget counts on, which only the test moves.
    clock = :atomics.new(1, signed: true)

    handle =
      start_supervised!(
        {RunnerProcess,
         id: "run_events",
         keeper: ScriptedKeeper,
         spec: spec,
         owner: self(),
         events: self(),
         clock: fn -> :atomics.get(clock, 1) end}
      )

    assert_receive {RunnerProcess, ^handle, :ready}, 5_000
    [spawn] = ScriptedKeeper.spawns(keeper)
    {:ok, host: host, handle: handle, spawn: spawn, clock: clock}
  end

  defp move(%{clock: clock}, ms), do: :atomics.add(clock, 1, ms)

  # A subtree of the host's assigned to the runner: its root.
  defp assign!(%{host: host, handle: handle}) do
    attempt = ScriptedHost.attempt!(host)
    deadline = System.monotonic_time(:millisecond) + 5_000

    assert :ok =
             RunnerProcess.assign(
               handle,
               attempt.assignment,
               attempt.input,
               attempt.keys,
               host.url,
               deadline
             )

    attempt.execution_id
  end

  defp write(%{spawn: spawn}, messages),
    do: :ok = ScriptedKeeper.write(spawn, Enum.map(messages, &RunnerControl.encode/1))

  defp cancel(parent, n \\ 1),
    do: %{
      type: :event,
      name: "formula.cancel",
      measurements: %{system_time: n},
      metadata: %{parent_execution_id: parent, task_id: "task_#{n}"}
    }

  defp tool(execution),
    do: %{
      type: :event,
      name: "mcp_tool.call",
      measurements: %{duration_ms: 1},
      metadata: %{execution_id: execution, tool_action: "component.search", status: "ok"}
    }

  defp request(component_ref \\ "c:local.x:0.1.0"),
    do: %{
      type: :event,
      name: "http.request",
      measurements: %{duration_ms: 1, system_time: 1},
      metadata: %{
        component_ref: component_ref,
        method: "GET",
        hostname: "a.test",
        status: 200
      }
    }

  defp await(task),
    do: %{
      type: :event,
      name: "formula.await",
      measurements: %{duration_ms: 1},
      metadata: %{task_id: task, status: "completed"}
    }

  defp storage,
    do: %{
      type: :event,
      name: "storage.call",
      measurements: %{duration_ms: 1},
      metadata: %{component_ref: "c:local.x:0.1.0", action: "read", status: "ok"}
    }

  defp child(execution),
    do: %{type: :child, execution_id: execution, attempt: "att_" <> execution}

  defp complete(root), do: %{type: :complete, execution_id: root, clean: true}

  # Every event the handle forwarded until none came for a while, oldest
  # first, and when the last of them came.
  defp forwarded(acc \\ [], last \\ nil) do
    receive do
      {:"$gen_cast", {:event, event}} ->
        forwarded([event | acc], System.monotonic_time(:millisecond))
    after
      300 -> {Enum.reverse(acc), last}
    end
  end

  # How many counts of what it dropped, and how many first drops, a log
  # says of this test's runner: other tests' runners log beside it.
  defp counts(log),
    do: length(Regex.scan(~r/runner run_events: \d+ of its events were dropped/, log))

  defp firsts(log), do: length(String.split(log, "runner run_events: an event was dropped")) - 1

  # The handle's end, and what it logged as it ended.
  defp ended(context) do
    capture_log(fn -> :ok = stop_supervised(RunnerProcess) end)
    |> tap(fn _log -> refute Process.alive?(context.handle) end)
  end

  test "a runner that has held nothing has every event dropped, its count said once as its handle ends",
       context do
    write(context, [cancel("exec_somebody"), request(), tool("exec_somebody")])
    assert {[], nil} = forwarded()

    log = ended(context)
    assert log =~ "runner run_events: 3 of its events were dropped, 3 not of a subtree it held"
    assert counts(log) == 1
  end

  test "an event of the subtree held is forwarded, its root's, a child's it named and one naming " <>
         "none; one naming another execution is dropped",
       context do
    root = assign!(context)
    write(context, [child("exec_child")])
    assert_receive {RunnerProcess, _handle, {:message, %{type: :child}}}, 5_000

    write(context, [
      cancel(root),
      tool("exec_child"),
      request(),
      cancel("exec_somebody"),
      tool("exec_somebody_else")
    ])

    {events, _last} = forwarded()
    assert events == [cancel(root), tool("exec_child"), request()]

    assert ended(context) =~
             "runner run_events: 2 of its events were dropped, 2 not of a subtree it held and 0 past"
  end

  test "a run's events before its complete and its final ones after it are forwarded, as long " <>
         "as it is the run held last",
       context do
    first = assign!(context)
    write(context, [cancel(first, 1), complete(first), cancel(first, 2)])
    assert_receive {RunnerProcess, _handle, {:message, %{type: :complete}}}, 5_000
    assert {[_, _] = events, _last} = forwarded()
    assert events == [cancel(first, 1), cancel(first, 2)]

    # The next run held: the first is the run held last, whose final
    # events are still its own.
    second = assign!(context)
    write(context, [cancel(first, 3), cancel(second, 4), complete(second)])
    assert_receive {RunnerProcess, _handle, {:message, %{type: :complete}}}, 5_000
    assert {[_, _], _last} = forwarded()

    # A run before the last is no longer the runner's to speak for.
    third = assign!(context)
    write(context, [cancel(first, 5), cancel(second, 6), cancel(third, 7)])
    {events, _last} = forwarded()
    assert events == [cancel(second, 6), cancel(third, 7)]
    assert ended(context) =~ "1 of its events were dropped, 1 not of a subtree it held"
  end

  test "an event naming no execution is forwarded only while its runner holds a subtree: once " <>
         "the subtree ended, an idle runner's are dropped, one naming the run held last is not",
       context do
    root = assign!(context)
    write(context, [request(), await("task_1"), storage()])
    {events, _last} = forwarded()
    assert events == [request(), await("task_1"), storage()]

    write(context, [complete(root)])
    assert_receive {RunnerProcess, _handle, {:message, %{type: :complete}}}, 5_000

    # Idle: an event naming no execution, of another component or none,
    # names no subtree it holds, at once as much as later.
    write(context, [
      request("catalyst:someone-else.thing:9.9.9"),
      await("task_x"),
      storage(),
      cancel(root)
    ])

    {events, _last} = forwarded()
    assert events == [cancel(root)]

    # Held again, the next subtree's are its own.
    log = capture_log(fn -> assign!(context) end)
    write(context, [request(), await("task_2")])
    {events, _last} = forwarded()
    assert events == [request(), await("task_2")]

    assert log =~
             "runner run_events: 3 of its events were dropped, 3 not of a subtree it held and 0 past"

    assert context |> ended() |> counts() == 0
  end

  test "a subtree's first dropped event is said as it is dropped, once, and how many it dropped " <>
         "as the subtree ends, the next subtree's apart",
       context do
    root = assign!(context)

    log =
      capture_log(fn ->
        write(context, [tool("exec_somebody"), tool("exec_somebody_else"), cancel(root)])
        assert {[_forwarded], _last} = forwarded()
      end)

    assert log =~
             "runner run_events: an event was dropped, not of a subtree it holds; how many " <>
               "follows as its subtree begins or ends, or its handle does"

    assert firsts(log) == 1
    assert counts(log) == 0

    log =
      capture_log(fn ->
        write(context, [tool("exec_somebody"), complete(root)])
        assert_receive {RunnerProcess, _handle, {:message, %{type: :complete}}}, 5_000
        assert %{id: "run_events"} = RunnerProcess.info(context.handle)
      end)

    assert firsts(log) == 0

    assert log =~
             "runner run_events: 3 of its events were dropped, 3 not of a subtree it held and 0 past"

    # The next subtree's first drop is said again, and its count alone as
    # the handle ends.
    second = assign!(context)

    log =
      capture_log(fn ->
        write(context, [tool("exec_somebody"), cancel(second)])
        assert {[_forwarded], _last} = forwarded()
      end)

    assert log =~ "runner run_events: an event was dropped, not of a subtree it holds"
    log = ended(context)
    assert log =~ "runner run_events: 1 of its events were dropped, 1 not of a subtree it held"
    assert counts(log) == 1
  end

  test "past its budget a runner's events are dropped and counted, and the budget regains its " <>
         "rate a second on its clock, up to the burst",
       context do
    root = assign!(context)
    sent = @burst + 144
    batch = fn -> write(context, Enum.map(1..sent, &cancel(root, &1))) end

    # The burst at once, the clock still.
    batch.()
    {events, _last} = forwarded()
    assert Enum.map(events, & &1.measurements.system_time) == Enum.to_list(1..@burst)

    # A second on, a second's rate; half a second on, half of it.
    move(context, 1_000)
    batch.()
    {events, _last} = forwarded()
    assert Enum.map(events, & &1.measurements.system_time) == Enum.to_list(1..@per_second)

    move(context, 500)
    batch.()
    {events, _last} = forwarded()
    assert length(events) == div(@per_second, 2)

    # A minute on, no more than the burst.
    move(context, 60_000)
    batch.()
    {events, _last} = forwarded()
    assert length(events) == @burst

    over = 4 * sent - 2 * @burst - @per_second - div(@per_second, 2)

    assert ended(context) =~
             "runner run_events: #{over} of its events were dropped, 0 not of a subtree it held " <>
               "and #{over} past its budget of #{@burst} at once and #{@per_second} a second"
  end
end
