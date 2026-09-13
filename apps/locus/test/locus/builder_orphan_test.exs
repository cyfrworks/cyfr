# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.BuilderOrphanTest do
  @moduledoc """
  The build task is unlinked from the caller, so neither death reaches the
  other: the caller is the process holding the deadline inside
  `Task.yield/2`, and the task is the one owning the port. Before the
  watcher monitored both, killing the caller left the task running with
  nothing left to time it out.

  What is asserted here is the part that is deterministic — which processes
  the watcher ends, and which it leaves alone. The OS half is deliberately
  not asserted; see the note on `kill_os_process/1` below.

  Not async: the watcher kills process groups, and the OS is shared.
  """

  use ExUnit.Case, async: false

  alias Locus.Builder

  # `kill_os_process/1` is exercised in production by the timeout path and
  # by this watcher, and it is not asserted here. Against a port child
  # killed immediately after it starts, its group kill answers `{"", 0}` —
  # success, no output — and the process is still running five seconds
  # later; the identical command from the test then ends it first time.
  # Observed on Linux in CI, never on macOS, with the pid confirmed by `ps`
  # to lead its own group and to be the port's own child. Four explanations
  # were tried and ruled out: a zombie awaiting reaping, a missing `kill`,
  # a group that does not exist, and a child that had not yet exec'd (the
  # child now announces itself before anything touches it). It is recorded
  # in the ledger rather than asserted, because a test that cannot say why
  # it passes is worth less than a note that says what was seen.

  describe "watch_for_orphans/3" do
    test "a dead caller ends the task it orphaned" do
      caller = spawn_idle()
      task = spawn_idle()
      task_ref = Process.monitor(task)

      Builder.watch_for_orphans(task, caller, no_such_pid())
      Process.exit(caller, :kill)

      # Without this the task would sit in `collect_port_output/3` for the
      # length of a build nobody is waiting for.
      assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 5_000
    end

    test "a dead task never takes the caller with it" do
      caller = spawn_idle()
      caller_ref = Process.monitor(caller)
      task = spawn_idle()

      Builder.watch_for_orphans(task, caller, no_such_pid())
      Process.exit(task, :kill)

      # The caller owns the result and its own deadline.
      refute_receive {:DOWN, ^caller_ref, :process, ^caller, _}, 500

      Process.exit(caller, :kill)
    end

    test "a task that finishes normally ends nobody" do
      caller = spawn_idle()
      caller_ref = Process.monitor(caller)

      # Alive when the watcher arms, as it is in the builder: the watcher is
      # started from inside the task. Monitoring a process that has already
      # gone reports :noproc, which reads as an abnormal death.
      task = spawn(fn -> receive(do: (:finish -> :ok)) end)

      Builder.watch_for_orphans(task, caller, no_such_pid())
      send(task, :finish)

      refute_receive {:DOWN, ^caller_ref, :process, ^caller, _}, 500

      Process.exit(caller, :kill)
    end
  end

  defp spawn_idle, do: spawn(fn -> Process.sleep(:infinity) end)

  # A pid the cleanup will find nothing for, so these cases turn on process
  # lifetimes alone and signal nothing outside the VM.
  defp no_such_pid, do: 2_147_483_646
end
