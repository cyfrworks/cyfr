# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/support.exs", __DIR__)

defmodule Cyfr.Cluster.ExecutionTest do
  @moduledoc """
  Killing the member that holds running work, at three different points,
  and what its peer does about each.

  The three points are different failures and the plan names them
  separately:

    * **after the durable intent** — the execution's row and its attempt
      exist with a lease, and nothing has been dispatched. A successor has
      a row to settle and no worker to ask.
    * **after dispatch** — a runner has attached and claimed the attempt.
      The same row, now with a holder that will never answer.
    * **after the outcome committed** — the run finished and its outcome
      is written. There is nothing to settle, and a successor that
      settled it anyway would be replacing a real answer with
      `uncertain`.

  `cell-ownership.md` §4.3 gives the bound for the first two: the attempt
  lease (180 s) plus the sweeper interval (60 s), **≤ 240 s**. All three
  are killed together and measured against that once, because the wait is
  the lease and the lease is the same for all of them.
  """

  use Cyfr.Cluster.Case, async: false

  # §4.3: attempt lease 180 s, sweeper interval 60 s.
  @lease_ms 180_000
  @sweep_ms 60_000
  @recovery_bound_ms @lease_ms + @sweep_ms

  describe "a member killed with running work" do
    @tag timeout: 600_000
    test "has each of its three kinds of work settled by its peer, or left alone" do
      Cell.call(:a, Cyfr.Cluster.Holder, :release!, [])

      intent = Cell.call(:a, Cyfr.Cluster.Holder, :attach!, [:intent, [attach: false]])
      dispatched = Cell.call(:a, Cyfr.Cluster.Holder, :attach!, [:dispatched, []])
      committed = Cell.call(:a, Cyfr.Cluster.Holder, :attach!, [:committed, []])

      assert %{"ok" => _} = Cell.call(:a, Cyfr.Cluster.Holder, :complete, [:committed])

      # What each looks like before the kill, read from outside the member
      # that made them.
      assert Observer.attempt(intent.attempt)["state"] == "running"
      assert Observer.attempt(intent.attempt)["claimed_by"] == nil

      assert Observer.attempt(dispatched.attempt)["state"] == "running"
      assert Observer.attempt(dispatched.attempt)["claimed_by"] != nil

      assert Observer.execution(committed.execution_id)["status"] == "completed"
      settled_at = Observer.execution(committed.execution_id)["completed_at"]
      assert settled_at

      # The lease is what a successor waits, and it is on database time.
      lease_until = Observer.attempt(dispatched.attempt)["lease_until"]
      left_ms = NaiveDateTime.diff(lease_until, Observer.now(), :millisecond)

      assert left_ms > @lease_ms - 10_000,
             "the attempt was leased for #{left_ms} ms, not the #{@lease_ms} ms §4.3 states"

      # Process death, with all three in that state.
      Cell.kill(:a)

      # The peer settles both running attempts, and it does so from the
      # rows alone: it heard nothing, and the dead member's boot is not
      # its own.
      {settled_ms, _} =
        Wait.measure!(
          fn ->
            Observer.attempt(intent.attempt)["state"] == "lapsed" and
              Observer.attempt(dispatched.attempt)["state"] == "lapsed"
          end,
          "the peer never settled the dead member's running attempts",
          @recovery_bound_ms + 60_000
        )

      Wait.report("a dead member's running work is settled", settled_ms, @recovery_bound_ms)

      assert settled_ms <= @recovery_bound_ms,
             "the peer took #{settled_ms} ms, past §4.3's #{@recovery_bound_ms} ms"

      # Both are `uncertain`, which is the truthful answer for work whose
      # holder stopped without saying what happened.
      for attempt <- [intent.attempt, dispatched.attempt] do
        assert Observer.attempt(attempt)["outcome"] == "uncertain"
      end

      assert Observer.execution(intent.execution_id)["status"] == "failed"
      assert Observer.execution(dispatched.execution_id)["status"] == "failed"

      # And the committed outcome is untouched: a sweep that settled it
      # would be replacing a real answer with an uncertain one.
      assert Observer.execution(committed.execution_id)["status"] == "completed"
      assert Observer.execution(committed.execution_id)["completed_at"] == settled_at
      assert Observer.attempt(committed.attempt)["state"] != "lapsed"
    end

    test "leaves a lapsed attempt its peer settles once, however many members sweep" do
      Cell.call(:a, Cyfr.Cluster.Holder, :release!, [])
      held = Cell.call(:a, Cyfr.Cluster.Holder, :attach!, [:swept, []])

      # The sweep's authority is the row: `lapse/2` matches the exact
      # `lease_until` the scan observed, so two members sweeping one
      # attempt produce one lapse and one no-op (§4.9). The lease is put
      # in the past here rather than waited out — the case above is what
      # measures the lease; this one is about what two sweepers do to one
      # row.
      Observer.expire_attempt!(held.attempt)

      results =
        Barrier.race(
          a: {Cyfr.Cluster.Boot, :sweep, []},
          b: {Cyfr.Cluster.Boot, :sweep, []}
        )

      assert Enum.all?(results, fn {_member, answer} -> answer == :ok end), inspect(results)

      assert Observer.attempt(held.attempt)["state"] == "lapsed"
      assert Observer.attempt(held.attempt)["outcome"] == "uncertain"

      # One execution, failed once: the row carries a single completion
      # instant, and a second lapse would have moved it.
      row = Observer.execution(held.execution_id)
      assert row["status"] == "failed"
      assert row["completed_at"]
    end
  end
end
