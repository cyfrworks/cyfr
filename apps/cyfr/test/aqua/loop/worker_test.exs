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
end
