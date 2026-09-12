# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.BuilderOrphanTest do
  @moduledoc """
  The build task is unlinked from the caller, so neither death reaches the
  toolchain on its own: closing the port signals the direct child, never the
  process group, and the caller is the process holding the deadline.
  """

  use ExUnit.Case, async: true

  alias Locus.Builder

  describe "watch_for_orphans/3" do
    test "a dead caller stops the OS process and the task it orphaned" do
      {port, os_pid} = spawn_sleeper()
      caller = spawn_idle()
      task = spawn_idle()

      Builder.watch_for_orphans(task, caller, os_pid)
      Process.exit(caller, :kill)

      assert until_true(fn -> not os_alive?(os_pid) end),
             "the toolchain process outlived the caller that was waiting on it"

      assert until_true(fn -> not Process.alive?(task) end),
             "the task was left holding a port onto a process that is gone"

      close(port)
    end

    test "a dead task stops the OS process and never touches the caller" do
      {port, os_pid} = spawn_sleeper()
      caller = spawn_idle()
      task = spawn_idle()

      Builder.watch_for_orphans(task, caller, os_pid)
      Process.exit(task, :kill)

      assert until_true(fn -> not os_alive?(os_pid) end)

      # The caller owns the result. Reaping the group must not take it down.
      Process.sleep(50)
      assert Process.alive?(caller)

      Process.exit(caller, :kill)
      close(port)
    end

    test "an ordinary exit leaves the OS process alone" do
      {port, os_pid} = spawn_sleeper()
      caller = spawn_idle()

      # The task has to still be alive when the watcher arms, which is what
      # happens in the builder: the watcher is started from inside it.
      # Monitoring a process that has already gone reports :noproc rather
      # than :normal, and the watcher reads that as an abnormal death.
      task = spawn(fn -> receive(do: (:finish -> :ok)) end)

      Builder.watch_for_orphans(task, caller, os_pid)
      send(task, :finish)

      Process.sleep(100)
      assert os_alive?(os_pid), "a task that finished normally reaped a live build"

      Process.exit(caller, :kill)
      close(port)
    end
  end

  defp spawn_sleeper do
    port =
      Port.open({:spawn_executable, System.find_executable("sleep")}, [
        :binary,
        :exit_status,
        {:args, ["300"]}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {port, os_pid}
  end

  defp spawn_idle, do: spawn(fn -> Process.sleep(:infinity) end)

  defp os_alive?(os_pid) do
    {_, code} = System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true)
    code == 0
  end

  defp until_true(fun, attempts \\ 100)
  defp until_true(_fun, 0), do: false

  defp until_true(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      until_true(fun, attempts - 1)
    end
  end

  defp close(port), do: if(Port.info(port), do: Port.close(port))
end
