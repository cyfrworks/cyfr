# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.FacadeTest do
  @moduledoc """
  The execution domain's door for callers outside it is an exact roster:
  an entry added without a roster change fails here. The lease keeper's
  entries answer as `Opus.LeaseWatch` does; `list_by_request/3` and
  `count_by_request/2` are the request log's correlation reads, the
  executions a request id ran, which `PrismWeb.ActivitiesLive` calls
  under its context beside `Sanctum.PolicyLog`'s own reads.
  `read_threads/2` is the read Aqua's loop makes of a child whose step
  closes without a completion result to carry its read threads.
  `ungranted/2` is why a grant a turn needs is missing, revoked by its
  person or not: Aqua's loop must say which and reaches Sanctum only
  through this door. `loads_packs?/1` is whether a program row's driver
  loads the athanor's packs as its program's own skills
  (`Opus.Programs.Definition`): Aqua's program harness gives it as the
  turn's `loader?` and reaches the execution domain only through this
  door.
  """

  use ExUnit.Case, async: true

  @roster [
    admit_child: 5,
    adopt_turn_root: 3,
    authority_for: 3,
    authority_for: 4,
    available?: 0,
    available?: 1,
    cancel: 2,
    claim_turn_root: 3,
    count_by_request: 2,
    end_schedule_turn: 4,
    end_turn_programs: 2,
    events_since: 3,
    feeds: 1,
    get: 2,
    list_by_request: 3,
    loads_packs?: 1,
    pause_turn_root: 3,
    read_threads: 2,
    release_turn_root: 3,
    resume_lease_watch: 1,
    resume_turn_root: 3,
    run_child: 5,
    run_root: 5,
    run_root_edge: 5,
    # What a schedule's fire says, which Aqua sends and the schedule tool
    # bounds at every write: one wording for both.
    schedule_fire_text: 2,
    service: 0,
    start_lease_watch: 2,
    start_lease_watch: 3,
    start_root: 5,
    stop_lease_watch: 1,
    subscribe_events: 2,
    suspend_lease_watch: 1,
    ungranted: 2,
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
  end

  # The processes monitoring `pid`.
  defp monitors(pid) do
    {:monitored_by, monitors} = Process.info(pid, :monitored_by)
    monitors
  end
end
