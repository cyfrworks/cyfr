# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.FacadeTest do
  @moduledoc """
  The execution domain's door for callers outside it is an exact roster:
  an entry added without a roster change fails here. The lease keeper's
  entries answer as `Opus.LeaseWatch` does; `list_by_request/3` and
  `count_by_request/2` are the request log's correlation reads, the
  executions a request id ran, which `PrismWeb.ActivitiesLive` calls
  under its context beside `Sanctum.PolicyLog`'s own reads. `sources/2`
  is the ledger read Aqua's loop makes for a child whose step closes
  without a completion result to carry it.
  """

  use ExUnit.Case, async: true

  @roster [
    admit_child: 5,
    adopt_turn_root: 3,
    authority_for: 3,
    authority_for: 4,
    available?: 0,
    cancel: 2,
    claim_turn_root: 2,
    claim_turn_root: 3,
    count_by_request: 2,
    events_since: 3,
    feeds: 1,
    get: 2,
    invoke_tincture: 3,
    list: 1,
    list: 2,
    list_by_request: 3,
    pause_turn_root: 3,
    release_turn_root: 3,
    resume_lease_watch: 1,
    resume_turn_root: 3,
    run_child: 5,
    run_root: 4,
    run_root: 5,
    run_root_edge: 5,
    service: 0,
    sources: 2,
    start_lease_watch: 2,
    start_lease_watch: 3,
    stop_lease_watch: 1,
    subscribe_events: 2,
    suspend_lease_watch: 1,
    unsubscribe_events: 2
  ]

  test "the root answers exactly its roster" do
    exported =
      Opus.__info__(:functions)
      |> Enum.reject(fn {name, _arity} -> name in [:__info__, :module_info] end)
      |> Enum.sort()

    assert exported == @roster
  end

  test "a lease keeper started through the root stops without touching its holder" do
    # This process holds the keeper, so a kill the stop let through would
    # end the test with it.
    assert {:ok, keeper} =
             Opus.start_lease_watch("exe_facade", "att_facade", tick_ms: 60_000)

    # The keeper watches its holder from its own process: the stop waits
    # for that watch, so it lands after it.
    Prima.Test.Wait.wait_until(fn -> keeper in monitors(self()) end)

    ref = Process.monitor(keeper)
    assert :ok = Opus.stop_lease_watch(keeper)
    assert_receive {:DOWN, ^ref, :process, ^keeper, :killed}

    # A dying process signals its links before it drops its monitors, so
    # once the keeper's watch is gone, an exit the stop let through has
    # reached this process.
    Prima.Test.Wait.wait_until(fn -> keeper not in monitors(self()) end)
    assert :ok = Opus.stop_lease_watch(nil)
  end

  # The processes monitoring `pid`.
  defp monitors(pid) do
    {:monitored_by, monitors} = Process.info(pid, :monitored_by)
    monitors
  end
end
