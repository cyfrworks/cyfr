# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.RunnerProcessEventsTest do
  @moduledoc """
  A runner's operator events are its word, and its handle
  (`Locus.Runtime.RunnerProcess`) forwards one only for what the runner
  holds: an event every execution of which is of the subtree it holds
  now, its root and each child it named, or of the one it held last, so a
  run's final events reach the forwarder on either side of its
  `complete`; any other event, and every event of a runner that has held
  nothing, is dropped. Each runner's events draw on a budget of their own
  (`Prima.RunnerControl.event_burst/0`, regaining
  `Prima.RunnerControl.events_per_second/0` a second), and past it are
  dropped. What is dropped is counted, and said once, as the handle ends.
  The test is the runner, over a scripted keeper, and the forwarder too.
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

    handle =
      start_supervised!(
        {RunnerProcess,
         id: "run_events", keeper: ScriptedKeeper, spec: spec, owner: self(), events: self()}
      )

    assert_receive {RunnerProcess, ^handle, :ready}, 5_000
    [spawn] = ScriptedKeeper.spawns(keeper)
    {:ok, host: host, handle: handle, spawn: spawn}
  end

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

  defp request,
    do: %{
      type: :event,
      name: "http.request",
      measurements: %{duration_ms: 1, system_time: 1},
      metadata: %{
        component_ref: "c:local.x:0.1.0",
        method: "GET",
        hostname: "a.test",
        status: 200
      }
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

  # The handle's end, and what it logged as it ended.
  defp ended(context) do
    capture_log(fn -> :ok = stop_supervised(RunnerProcess) end)
    |> tap(fn _log -> refute Process.alive?(context.handle) end)
  end

  test "a runner that has held nothing has every event dropped, said once as its handle ends",
       context do
    write(context, [cancel("exec_somebody"), request(), tool("exec_somebody")])
    assert {[], nil} = forwarded()

    log = ended(context)
    assert log =~ "runner run_events: 3 of its events were dropped, 3 not of a subtree it held"
    assert length(String.split(log, "of its events were dropped")) == 2
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

  test "past its budget a runner's events are dropped and counted, and the budget regains its " <>
         "rate a second",
       context do
    root = assign!(context)
    sent = @burst + 144
    started = System.monotonic_time(:millisecond)
    write(context, Enum.map(1..sent, &cancel(root, &1)))
    {events, last} = forwarded()

    # The burst at once, and what the rate regained while they were read.
    regained = div((last - started) * @per_second, 1_000) + 1
    assert length(events) >= @burst
    assert length(events) <= @burst + regained
    assert Enum.map(events, & &1.measurements.system_time) == Enum.to_list(1..length(events))
    over = sent - length(events)
    assert over > 0

    # A second later the budget has regained a second's rate, and no more
    # than the burst.
    refute_receive {:"$gen_cast", {:event, _}}, 1_000
    write(context, Enum.map(1..sent, &cancel(root, &1)))
    {events, _last} = forwarded()
    assert length(events) >= @per_second
    assert length(events) <= @burst
    over = over + sent - length(events)

    assert ended(context) =~
             "runner run_events: #{over} of its events were dropped, 0 not of a subtree it held " <>
               "and #{over} past its budget of #{@burst} at once and #{@per_second} a second"
  end
end
