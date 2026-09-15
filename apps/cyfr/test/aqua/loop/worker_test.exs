# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.WorkerTest do
  @moduledoc "A worker answers its loop and dies with it."

  use ExUnit.Case, async: true

  alias Aqua.Loop.Worker

  test "a worker's answer reaches the loop that awaits it" do
    assert Task.await(Worker.async(fn -> :answered end)) == :answered
  end

  @tag capture_log: true
  test "a worker's death is answered to its loop, which keeps running" do
    task = Worker.async(fn -> exit(:boom) end)
    assert Task.yield(task, 5_000) == {:exit, :boom}
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
end
