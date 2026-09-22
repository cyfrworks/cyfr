# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/support.exs", __DIR__)

defmodule Cyfr.Cluster.SharedAuthorityTest do
  @moduledoc """
  The tenant's durable ceilings, claimed from two members at once: one
  consent budget and one invocation rate.

  `cell-ownership.md` §5 says the invoke-budget ETS counter is advisory
  because "the durable reservation is on the path for **every** spawn",
  and names the case this file carries: *two members, one budget, the ETS
  counters cold on both, and the reservation rows must still hold the
  ceiling*. §4.6 says the same of the rate window: never more than `cap`
  admitted in any aligned window of `window_ms`, across the whole cell.

  Both are measured as **deltas against rows nothing else writes**: the
  budget and the bucket are this case's own, and the assertion is on what
  the two members together were admitted, never on an absolute the
  database carries between runs.
  """

  use Cyfr.Cluster.Case, async: false

  describe "one consent budget" do
    test "holds its cap across both members, with neither member's counter warm" do
      athanor = Cell.call(:a, Cyfr.Cluster.Fixtures, :athanor!, ["budget"])
      cap = 6
      budget = Cell.call(:a, Cyfr.Cluster.Fixtures, :budget!, [athanor.id, cap])
      # A charge id is unique in the cell, not only in its reservation:
      # `budget_charges` is keyed by it. This database outlives the run,
      # so the case names its own.
      run = System.unique_integer([:positive])

      # The node-local counter is the fast gate in front of the row, and
      # it is cold on both members: neither has ever seen this budget. If
      # the counter were the authority, each member would admit `cap` of
      # its own.
      for id <- [:a, :b] do
        assert Cell.call(id, Cyfr.Cluster.Fixtures, :try_acquire, [budget.budget_id, cap]) == :ok,
               "member #{id}'s own counter refused a budget it has never seen"
      end

      # Eight charges, alternating between the members, against a cap of
      # six. Each charge has an id of its own, so none is a retry of
      # another, and a retry of one is deliberately included below.
      answers =
        for n <- 1..8 do
          member = if rem(n, 2) == 0, do: :b, else: :a

          {member,
           Cell.call(member, Cyfr.Cluster.Fixtures, :charge, [
             athanor.id,
             budget.budget_id,
             budget.attempt,
             "cluster-charge-#{run}-#{n}"
           ])}
        end

      admitted = Enum.count(answers, fn {_member, answer} -> answer == :ok end)
      refused = Enum.count(answers, fn {_member, answer} -> answer == :exhausted end)

      assert admitted == cap,
             "the cell admitted #{admitted} of #{cap}: #{inspect(answers)}"

      assert refused == 8 - cap

      # Both members took part, or the case proved only that one member
      # can count.
      for member <- [:a, :b] do
        assert Enum.any?(answers, fn {m, answer} -> m == member and answer == :ok end),
               "member #{member} was admitted nothing, so the cap was not shared"
      end

      # The row is what held it, and it reads the same from either member.
      for id <- [:a, :b] do
        assert Cell.call(id, Cyfr.Cluster.Fixtures, :charged, [athanor.id, budget.budget_id]) ==
                 cap
      end
    end

    test "a charge asked for twice is one charge, whichever member asks" do
      athanor = Cell.call(:a, Cyfr.Cluster.Fixtures, :athanor!, ["retry"])
      budget = Cell.call(:a, Cyfr.Cluster.Fixtures, :budget!, [athanor.id, 2])

      args = [
        athanor.id,
        budget.budget_id,
        budget.attempt,
        "cluster-retried-#{System.unique_integer([:positive])}"
      ]

      assert Cell.call(:a, Cyfr.Cluster.Fixtures, :charge, args) == :ok
      assert Cell.call(:b, Cyfr.Cluster.Fixtures, :charge, args) == :ok

      assert Cell.call(:a, Cyfr.Cluster.Fixtures, :charged, [athanor.id, budget.budget_id]) == 1,
             "the same charge id counted twice because it arrived at two members"
    end
  end

  describe "one invocation rate" do
    test "admits no more than the cap across both members in one window" do
      athanor = Cell.call(:a, Cyfr.Cluster.Fixtures, :athanor!, ["rate"])
      bucket = "cluster-bucket-#{System.unique_integer([:positive])}"
      cap = 5
      window_ms = 60_000

      answers =
        for n <- 1..10 do
          member = if rem(n, 2) == 0, do: :b, else: :a

          {member,
           Cell.call(member, Cyfr.Cluster.Fixtures, :take_rate, [
             athanor.id,
             bucket,
             cap,
             window_ms
           ])}
        end

      admitted = Enum.count(answers, fn {_m, answer} -> match?({:ok, _}, answer) end)

      assert admitted == cap,
             "the cell admitted #{admitted} claims against a cap of #{cap}: #{inspect(answers)}"

      for member <- [:a, :b] do
        assert Enum.any?(answers, fn {m, answer} -> m == member and match?({:ok, _}, answer) end),
               "member #{member} was admitted nothing, so the window was not shared"
      end

      # The window is the row, and the count is what both members put in
      # it. Read from outside both.
      window = Observer.rate_window(athanor.id, bucket)
      assert window["count"] == cap
      assert window["window_ms"] == window_ms

      # And the refusal is the ceiling, with the wait it names — not an
      # error either member invented.
      assert Enum.any?(answers, fn {_m, answer} ->
               match?({:refused, retry} when is_integer(retry) and retry > 0, answer)
             end)
    end

    test "two members claiming the last allowance at one instant admit one of them" do
      athanor = Cell.call(:a, Cyfr.Cluster.Fixtures, :athanor!, ["rate-race"])
      bucket = "cluster-race-#{System.unique_integer([:positive])}"

      # A cap of one, and both members released from a barrier: whatever
      # the scheduler does with them, the row admits one.
      take = {Cyfr.Cluster.Fixtures, :take_rate, [athanor.id, bucket, 1, 60_000]}
      results = Barrier.race(a: take, b: take)

      admitted = Enum.count(results, fn {_m, answer} -> match?({:ok, _}, answer) end)

      assert admitted == 1,
             "two members claiming one allowance were both admitted: #{inspect(results)}"

      assert Observer.rate_window(athanor.id, bucket)["count"] == 1
    end
  end
end
