# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.WorkerTest do
  @moduledoc "A worker answers its loop and dies with it."

  use ExUnit.Case, async: false

  import Prima.Test.Wait

  alias Aqua.Loop.Worker

  test "a worker's answer reaches the loop that awaits it" do
    assert Worker.yield(Worker.async(fn -> :answered end), 5_000) == {:ok, :answered}
  end

  @tag capture_log: true
  test "a worker's death is answered to its loop, which keeps running" do
    task = Worker.async(fn -> exit(:boom) end)
    assert Worker.yield(task, 5_000) == {:exit, :boom}
  end

  test "a worker, and the worker it started, die with the loop that started them" do
    test = self()

    loop =
      spawn(fn ->
        Worker.async(fn ->
          inner = Worker.async(fn -> Process.sleep(:infinity) end)
          send(test, {:workers, self(), inner.pid})
          Process.sleep(:infinity)
        end)

        Process.sleep(:infinity)
      end)

    assert_receive {:workers, outer, inner}, 5_000
    refs = Enum.map([outer, inner], &Process.monitor/1)

    Process.exit(loop, :kill)

    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, :killed}, 5_000)
  end

  test "a worker its owner releases late dies with the loop that started them, not before" do
    test = self()
    manager = Process.whereis(Worker)
    :ok = :sys.suspend(manager)
    on_exit(fn -> :sys.resume(manager) end)

    loop =
      spawn(fn ->
        Worker.async(fn ->
          inner = Worker.async(fn -> Process.sleep(:infinity) end)
          send(test, {:workers, self(), inner.pid})
          Process.sleep(:infinity)
        end)

        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(loop, :kill) end)
    wait_until(fn -> queued_start(manager) == loop end)

    # The manager answers the loop's start and suspends again: both system
    # messages are queued behind that start while the manager cannot run,
    # so the outer worker's own start, sent only once it is released, waits
    # behind them.
    true = :erlang.suspend_process(manager)
    tag = make_ref()
    send(manager, {:system, {self(), tag}, :resume})
    send(manager, {:system, {self(), tag}, :suspend})
    true = :erlang.resume_process(manager)
    assert_receive {^tag, :ok}
    assert_receive {^tag, :ok}
    wait_until(fn -> queued_start(manager) not in [nil, loop] end)
    outer = queued_start(manager)

    # The outer worker is held after the manager has started the inner one
    # and before it releases it, as a stalled scheduler would hold it: the
    # sleep is the stall, six seconds from the moment the inner worker
    # waits, longer than any bound this module keeps (a stop's five).
    true = :erlang.suspend_process(outer)
    :ok = :sys.resume(manager)
    wait_until(fn -> waiting_worker(outer) end, 5_000, "the inner worker to await its release")
    Process.sleep(6_000)
    true = :erlang.resume_process(outer)

    assert_receive {:workers, ^outer, inner}, 5_000
    refs = Enum.map([outer, inner], &Process.monitor/1)

    Process.exit(loop, :kill)

    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, :killed}, 5_000)
  end

  test "stopping an owner confirms every nested worker is stopped and leaves another owner running" do
    test = self()
    sibling = Worker.async(fn -> Process.sleep(:infinity) end)

    owner =
      spawn(fn ->
        Worker.async(fn ->
          nested = Worker.async(fn -> Process.sleep(:infinity) end)
          send(test, {:tree, self(), nested.pid})
          Process.sleep(:infinity)
        end)

        Process.sleep(:infinity)
      end)

    assert_receive {:tree, outer, inner}, 5_000
    assert :ok = Worker.stop(owner)
    for pid <- [owner, outer, inner], do: refute(Process.alive?(pid))
    assert Process.alive?(sibling.pid)
    assert :ok = Worker.stop(owner)
    Worker.shutdown(sibling)
  end

  test "a pending worker can be yielded and shut down" do
    task = Worker.async(fn -> Process.sleep(:infinity) end)
    assert Worker.yield(task, 0) == nil
    assert Worker.shutdown(task) == nil
    refute Process.alive?(task.pid)
  end

  test "a queued start from an owner that has died never runs its function" do
    test = self()
    manager = Process.whereis(Worker)
    :ok = :sys.suspend(manager)
    on_exit(fn -> :sys.resume(manager) end)
    owner = spawn(fn -> Worker.async(fn -> send(test, :ran) end) end)

    wait_until(fn ->
      {:messages, messages} = Process.info(manager, :messages)
      Enum.any?(messages, &match?({:"$gen_call", {^owner, _}, {:start, _, _}}, &1))
    end)

    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}
    :ok = :sys.resume(manager)
    _ = :sys.get_state(manager)
    refute_received :ran
  end

  # The caller of the first start queued at the manager, if any.
  defp queued_start(manager) do
    {:messages, messages} = Process.info(manager, :messages)

    Enum.find_value(messages, fn
      {:"$gen_call", {caller, _}, {:start, _, _}} -> caller
      _ -> nil
    end)
  end

  # A waiting worker that `owner` started: it names its owner first among
  # its callers.
  defp waiting_worker(owner) do
    Enum.find(Process.list(), fn pid ->
      case Process.info(pid, [:dictionary, :status]) do
        [dictionary: dictionary, status: :waiting] ->
          match?([^owner | _], dictionary[:"$callers"])

        _ ->
          false
      end
    end)
  end
end
