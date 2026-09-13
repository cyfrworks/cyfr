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

  describe "kill_os_process/1" do
    test "kills a process the builder started" do
      {port, os_pid} = spawn_sleeper()
      port_ref = Port.monitor(port)

      outcome = Builder.kill_os_process(os_pid)

      # Called straight from the test, not from a watcher, and reporting
      # exactly what the kills answered it.
      await_port_down(
        port_ref,
        port,
        os_pid,
        "kill_os_process/1 did not kill it; it saw #{inspect(outcome)}"
      )
    end
  end

  describe "watch_for_orphans/3" do
    test "a dead caller stops the OS process and the task it orphaned" do
      {port, os_pid} = spawn_sleeper()
      port_ref = Port.monitor(port)
      caller = spawn_idle()
      task = spawn_idle()
      task_ref = Process.monitor(task)

      Builder.watch_for_orphans(task, caller, os_pid)
      Process.exit(caller, :kill)

      # Monitor the port, not the pid. Asking the OS is wrong — a killed
      # child stays a zombie answering `kill -0` until the VM reaps it — and
      # `{:exit_status, _}` is not delivered for every way a port can end.
      # The port's own DOWN covers all of them.
      await_port_down(port_ref, port, os_pid, "the toolchain outlived its caller")
      assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 5_000
    end

    test "a dead task stops the OS process and never touches the caller" do
      {port, os_pid} = spawn_sleeper()
      port_ref = Port.monitor(port)
      caller = spawn_idle()
      caller_ref = Process.monitor(caller)
      task = spawn_idle()

      Builder.watch_for_orphans(task, caller, os_pid)
      Process.exit(task, :kill)

      await_port_down(port_ref, port, os_pid, "the toolchain outlived its task")

      # The caller owns the result. Reaping the group must not take it down.
      refute_receive {:DOWN, ^caller_ref, :process, ^caller, _}, 300

      Process.exit(caller, :kill)
    end

    test "a task that finishes normally leaves the OS process alone" do
      {port, os_pid} = spawn_sleeper()
      port_ref = Port.monitor(port)
      caller = spawn_idle()

      # The task has to be alive when the watcher arms, which is how the
      # builder does it: the watcher is started from inside the task.
      # Monitoring a process that has already gone reports :noproc, which
      # reads here as an abnormal death.
      task = spawn(fn -> receive(do: (:finish -> :ok)) end)

      Builder.watch_for_orphans(task, caller, os_pid)
      send(task, :finish)

      refute_receive {:DOWN, ^port_ref, :port, ^port, _}, 500

      Process.exit(caller, :kill)
      close(port, os_pid)
    end
  end

  # Waits until the child has actually exec'd. `Port.open/2` returns before
  # that, and `Port.info/2` answers with a pid the OS may not have finished
  # setting up: a kill sent then finds neither the pid nor its group, and
  # the builder reads two "No such process" answers as a job already done.
  # It says so in `already_gone?`, silently, which is right in general and
  # is exactly what made this test look like a broken cleanup.
  defp spawn_sleeper do
    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        {:args, ["-c", "echo ready; exec sleep 30"]}
      ])

    assert_receive {^port, {:data, "ready\n"}}, 5_000

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {port, os_pid}
  end

  defp spawn_idle, do: spawn(fn -> Process.sleep(:infinity) end)

  # A port's DOWN covers every way it can end, which `{:exit_status, _}`
  # does not. On failure, say what the OS thinks of the pid — whether it is
  # gone, running, or a zombie nobody reaped — so one run settles it.
  defp await_port_down(port_ref, port, os_pid, message) do
    receive do
      {:DOWN, ^port_ref, :port, ^port, _} -> :ok
    after
      5_000 -> flunk("#{message}; the OS says: #{os_state(os_pid)}")
    end
  end

  defp os_state(os_pid) do
    before = "#{ps(os_pid)}; pgid #{pgid(os_pid)}"
    group = inspect(kill(["-9", "-#{os_pid}"]))
    direct = inspect(kill(["-9", "#{os_pid}"]))
    Process.sleep(200)

    # Whether a kill that reports success actually ends the process. If it
    # is still there afterwards, the signal is reaching something other than
    # what `ps` is describing.
    "#{before}; group kill #{group}; direct kill #{direct}; then #{ps(os_pid)}"
  end

  defp ps(os_pid) do
    case System.cmd("ps", ["-o", "pid=,stat=,comm=", "-p", "#{os_pid}"], stderr_to_stdout: true) do
      {"", _} -> "pid #{os_pid} is gone"
      {out, 0} -> String.trim(out)
      {out, code} -> "ps exited #{code}: #{String.trim(out)}"
    end
  rescue
    e -> "ps unavailable: #{Exception.message(e)}"
  end

  defp pgid(os_pid) do
    case System.cmd("ps", ["-o", "pgid=", "-p", "#{os_pid}"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  # Whether killing works at all from here, and how. The builder's own
  # attempt logs nothing on the paths it believes succeeded, so repeating it
  # is the only way to see what the OS answered.
  defp kill(args) do
    System.cmd("kill", args, stderr_to_stdout: true)
  rescue
    e -> "kill unavailable: #{Exception.message(e)}"
  end

  defp close(port, os_pid) do
    if Port.info(port), do: Port.close(port)
    System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)
  end
end
