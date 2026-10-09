# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.FacadeTest do
  @moduledoc """
  The execution domain's door for callers outside it is an exact roster:
  an entry added without a roster change fails here. The lease keeper's
  entries answer as `Crucible.LeaseWatch` does.
  """

  use ExUnit.Case, async: true

  @roster [
    admit_child: 5,
    adopt_turn_root: 3,
    authority_for: 3,
    authority_for: 4,
    available?: 0,
    cancel: 2,
    cancel_for_restart: 3,
    claim_turn_root: 2,
    claim_turn_root: 3,
    events_since: 3,
    feeds: 1,
    get: 2,
    invoke_tincture: 3,
    list: 1,
    list: 2,
    pause_turn_root: 3,
    release_turn_root: 3,
    resume_lease_watch: 1,
    resume_turn_root: 3,
    run_child: 5,
    run_root: 4,
    run_root: 5,
    run_root_edge: 5,
    service: 0,
    start_lease_watch: 2,
    start_lease_watch: 3,
    stop_lease_watch: 1,
    subscribe_events: 2,
    suspend_lease_watch: 1,
    unsubscribe_events: 2
  ]

  test "the root answers exactly its roster" do
    exported =
      Crucible.__info__(:functions)
      |> Enum.reject(fn {name, _arity} -> name in [:__info__, :module_info] end)
      |> Enum.sort()

    assert exported == @roster
  end

  test "a lease keeper started through the root stops without touching its holder" do
    until = DateTime.add(DateTime.utc_now(), 60, :second)

    # This process holds the keeper, so a kill the stop let through would
    # end the test with it.
    assert {:ok, keeper} =
             Crucible.start_lease_watch("exe_facade", "att_facade", until: until, tick_ms: 60_000)

    # The keeper watches its holder from its own process: the stop waits
    # for that watch, so it lands after it.
    Prima.Test.Wait.wait_until(fn -> keeper in monitors(self()) end)

    ref = Process.monitor(keeper)
    assert :ok = Crucible.stop_lease_watch(keeper)
    assert_receive {:DOWN, ^ref, :process, ^keeper, :killed}

    # A dying process signals its links before it drops its monitors, so
    # once the keeper's watch is gone, an exit the stop let through has
    # reached this process.
    Prima.Test.Wait.wait_until(fn -> keeper not in monitors(self()) end)
    assert :ok = Crucible.stop_lease_watch(nil)
  end

  # The processes monitoring `pid`.
  defp monitors(pid) do
    {:monitored_by, monitors} = Process.info(pid, :monitored_by)
    monitors
  end
end
