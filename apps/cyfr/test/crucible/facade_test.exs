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
    get: 2,
    invoke_tincture: 3,
    list: 1,
    list: 2,
    pause_turn_root: 3,
    release_turn_root: 3,
    resume_turn_root: 3,
    run_child: 5,
    run_root: 4,
    run_root: 5,
    run_root_edge: 5,
    service: 0,
    start_lease_watch: 3,
    start_lease_watch: 4,
    stop_lease_watch: 1,
    subscribe_events: 2,
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
    holder = spawn(fn -> receive do: (:release -> :ok) end)
    until = DateTime.add(DateTime.utc_now(), 60, :second)

    assert {:ok, keeper} =
             Crucible.start_lease_watch(holder, "exe_facade", "att_facade",
               until: until,
               tick_ms: 60_000
             )

    ref = Process.monitor(keeper)
    assert :ok = Crucible.stop_lease_watch(keeper)
    assert_receive {:DOWN, ^ref, :process, ^keeper, :killed}
    assert Process.alive?(holder)
    assert :ok = Crucible.stop_lease_watch(nil)

    send(holder, :release)
  end
end
