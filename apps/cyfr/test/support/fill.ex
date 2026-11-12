# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.Fill do
  @moduledoc """
  The end of a background fill, awaited on the fill's own signal.

  A sign-in and a first need start the whole fill as a task under
  `Compendium.ProvisioningSupervisor` and answer at once. The task ends
  in a write to the athanor's row, which announces `:athanor_changed`
  (`Sanctum.Provisioning.mark_filled/1`, `record_failure/4`) from the
  task's own process, and then gives the claim back. `settled!/3`
  listens for that announcement from before the trigger runs, so none is
  missed, and once the athanor reads ready or failed it awaits the
  announcing task's end, so neither the claim's release nor anything
  else of the task's is still running when the test reads on. It never
  sleeps or polls: it waits on the announcement and on the task's
  monitor, under one deadline, and fails naming the athanor past it.

  `started!/2` is for a fill that announces nothing: one whose claim is
  held elsewhere or whose keeper could not be started. It runs the
  trigger and awaits the end of every fill task the trigger started, the
  tasks of `Compendium.ProvisioningSupervisor` whose callers include the
  test. A task is listed there from the moment the trigger's
  `start_child` answers until it ends, so none is missed.

  `tests/release-boot/fixture.exs`' `fill_settled` waits the same way on
  a release.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @deadline_ms 30_000

  @doc """
  Run `trigger` and wait for the background fill of `athanor_id` it
  started to settle and its task to end. Answers `{trigger's answer,
  :ready | :failed}`.
  """
  @spec settled!(String.t(), (-> result), pos_integer()) :: {result, :ready | :failed}
        when result: term()
  def settled!(athanor_id, trigger, deadline_ms \\ @deadline_ms)
      when is_binary(athanor_id) and is_function(trigger, 0) do
    me = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:cyfr, :sanctum, :notify],
        fn _event, _measurements, %{athanor_id: id, kind: kind}, _config ->
          if id == athanor_id and kind == :athanor_changed,
            do: send(me, {handler, self()})
        end,
        nil
      )

    try do
      answer = trigger.()
      deadline = System.monotonic_time(:millisecond) + deadline_ms
      {answer, await(athanor_id, handler, deadline)}
    after
      :telemetry.detach(handler)
    end
  end

  @doc """
  Run `trigger` and await the end of every background fill task it
  started. Answers what `trigger` answered.
  """
  @spec started!((-> result), pos_integer()) :: result when result: term()
  def started!(trigger, deadline_ms \\ @deadline_ms) when is_function(trigger, 0) do
    answer = trigger.()
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    me = self()

    for {:undefined, task, _type, _modules} <-
          Supervisor.which_children(Compendium.ProvisioningSupervisor),
        is_pid(task),
        me in callers(task),
        do: ended!("an athanor", task, deadline)

    answer
  end

  defp callers(task) do
    case Process.info(task, :dictionary) do
      {:dictionary, dictionary} -> Keyword.get(dictionary, :"$callers", [])
      nil -> []
    end
  end

  # The test's own announcements (a local half's failure, say) are not the
  # background fill's end; only one from another process, after which the
  # athanor reads settled, is.
  defp await(athanor_id, handler, deadline) do
    me = self()

    receive do
      {^handler, ^me} ->
        await(athanor_id, handler, deadline)

      {^handler, task} ->
        case Sanctum.Provisioning.status(Sanctum.Context.build(athanor_id: athanor_id)) do
          settled when settled in [:ready, :failed] ->
            ended!(athanor_id, task, deadline)
            settled

          _still ->
            await(athanor_id, handler, deadline)
        end
    after
      left(deadline) ->
        flunk("the background fill of #{athanor_id} did not settle in time")
    end
  end

  defp ended!(athanor_id, task, deadline) do
    ref = Process.monitor(task)

    receive do
      {:DOWN, ^ref, :process, ^task, _reason} -> :ok
    after
      left(deadline) ->
        Process.demonitor(ref, [:flush])
        flunk("the fill task #{inspect(task)} of #{athanor_id} did not end in time")
    end
  end

  defp left(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
