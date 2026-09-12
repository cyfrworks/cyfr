# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.BuilderOrphanTest do
  @moduledoc """
  The build task is unlinked from the caller, so neither death reaches the
  toolchain on its own: closing the port signals the direct child, never the
  process group, and the caller is the process holding the deadline.

  Not async: these kill process groups, and the OS is shared.
  """

  use ExUnit.Case, async: false

  alias Locus.Builder

  describe "watch_for_orphans/3" do
    test "a dead caller stops the OS process and the task it orphaned" do
      {port, os_pid} = spawn_sleeper()
      caller = spawn_idle()
      task = spawn_idle()
      task_ref = Process.monitor(task)

      Builder.watch_for_orphans(task, caller, os_pid)
      Process.exit(caller, :kill)

      # The port owner is told directly when its child ends, which beats
      # asking the OS: a killed pid lingers as a zombie until the VM reaps
      # it, and answers `kill -0` the whole time.
      assert_receive {^port, {:exit_status, _}}, 2_000
      assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 2_000
    end

    test "a dead task stops the OS process and never touches the caller" do
      {port, os_pid} = spawn_sleeper()
      caller = spawn_idle()
      caller_ref = Process.monitor(caller)
      task = spawn_idle()

      Builder.watch_for_orphans(task, caller, os_pid)
      Process.exit(task, :kill)

      assert_receive {^port, {:exit_status, _}}, 2_000

      # The caller owns the result. Reaping the group must not take it down.
      refute_receive {:DOWN, ^caller_ref, :process, ^caller, _}, 300

      Process.exit(caller, :kill)
    end

    test "a task that finishes normally leaves the OS process alone" do
      {port, os_pid} = spawn_sleeper()
      caller = spawn_idle()

      # The task has to be alive when the watcher arms, which is how the
      # builder does it: the watcher is started from inside the task.
      # Monitoring a process that has already gone reports :noproc, which
      # reads here as an abnormal death.
      task = spawn(fn -> receive(do: (:finish -> :ok)) end)

      Builder.watch_for_orphans(task, caller, os_pid)
      send(task, :finish)

      refute_receive {^port, {:exit_status, _}}, 300

      Process.exit(caller, :kill)
      close(port, os_pid)
    end
  end

  defp spawn_sleeper do
    port =
      Port.open({:spawn_executable, System.find_executable("sleep")}, [
        :binary,
        :exit_status,
        {:args, ["30"]}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {port, os_pid}
  end

  defp spawn_idle, do: spawn(fn -> Process.sleep(:infinity) end)

  defp close(port, os_pid) do
    if Port.info(port), do: Port.close(port)
    System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)
  end
end
