# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/support.exs", __DIR__)

defmodule Cyfr.Cluster.ProvisioningTest do
  @moduledoc """
  Two first touches of one estate, and the death of the member that won.

  `cell-ownership.md` §4.7 keeps provisioning's shape from F3: one row per
  athanor, `(owner, fence)` compare-and-set, a lease on database time. An
  estate is filled once whichever member the person's first request
  reaches, and a second member is told `:provisioning_busy` rather than
  filling it again beside the first.

  The owner is boot-scoped (`Cyfr.Boot.id() <> "/" <> …`), so a member
  that comes back never resumes its predecessor's claim: it waits the
  lease out like any other successor.
  """

  use Cyfr.Cluster.Case, async: false

  # §4.7's lease, from `Sanctum.Provisioning`: 60 s, renewed every 20 s.
  @lease_ms 60_000

  # What a successor may add to the lease: its own asking interval. This
  # case asks every 50 ms, so anything approaching this is the lease
  # itself being read late rather than the successor being slow.
  @ask_bound_ms 2_000

  describe "two first touches of one estate" do
    test "fill it once: the second member is told it is busy" do
      athanor = Cell.call(:a, Cyfr.Cluster.Fixtures, :athanor!, ["estate"])

      assert {:ok, claim} =
               Cell.call(:a, Cyfr.Cluster.Fixtures, :take_estate, [athanor.id, "first_need"])

      assert Cell.call(:b, Cyfr.Cluster.Fixtures, :take_estate, [athanor.id, "first_need"]) ==
               {:error, :provisioning_busy},
             "two members both took one estate's claim"

      # The row is the evidence, read from outside both, and it names the
      # boot that won — not the node, so a restart of that node is a
      # successor and not the same owner.
      row = Observer.row("SELECT * FROM provisioning_claims WHERE athanor_id = $1", [athanor.id])
      assert row["owner"] == claim.owner
      assert row["fence"] == claim.fence
      assert row["owner"] =~ to_string(Cell.member(:a).node)

      # And what the peer *sees* is a fill in progress, not an absence.
      assert Cell.call(:b, Cyfr.Cluster.Fixtures, :estate_status, [athanor.id]) == :filling
    end

    test "raced from a barrier, one of them fills it" do
      athanor = Cell.call(:a, Cyfr.Cluster.Fixtures, :athanor!, ["estate-race"])
      take = {Cyfr.Cluster.Fixtures, :take_estate, [athanor.id, "first_need"]}
      results = Barrier.race(a: take, b: take)

      won = for {member, {:ok, claim}} <- results, do: {member, claim}
      assert length(won) == 1, "two members filled one estate: #{inspect(results)}"

      losers = for {_m, answer} <- results, not match?({:ok, _}, answer), do: answer
      assert losers == [{:error, :provisioning_busy}], inspect(results)

      [{_member, claim}] = won

      assert Observer.row("SELECT * FROM provisioning_claims WHERE athanor_id = $1", [athanor.id])[
               "owner"
             ] == claim.owner
    end
  end

  describe "the member holding an estate dying" do
    @tag timeout: 400_000
    test "leaves a claim its peer takes over once the lease has run out, and not before" do
      athanor = Cell.call(:a, Cyfr.Cluster.Fixtures, :athanor!, ["estate-death"])

      assert {:ok, claim} =
               Cell.call(:a, Cyfr.Cluster.Fixtures, :take_estate, [athanor.id, "first_need"])

      # The row's own deadline, on database time. What a successor waits
      # is this instant and not a duration measured from anywhere else:
      # measuring from the kill would fold in how long the kill took and
      # how late the claim was read, and then the assertion would be
      # about the case rather than about the lease.
      lease_until =
        Observer.row("SELECT * FROM provisioning_claims WHERE athanor_id = $1", [athanor.id])[
          "lease_until"
        ]

      assert NaiveDateTime.diff(lease_until, Observer.now(), :millisecond) > @lease_ms - 5_000,
             "the claim was not leased for the 60 s §4.7 states"

      # Process death. Nothing is released and nothing renews, so the only
      # thing between the peer and the estate is that deadline.
      Cell.kill(:a)

      assert Cell.call(:b, Cyfr.Cluster.Fixtures, :take_estate, [athanor.id, "first_need"]) ==
               {:error, :provisioning_busy},
             "the peer took an estate whose claim was still standing"

      {_waited_ms, answer} =
        Wait.measure!(
          fn ->
            case Cell.call(:b, Cyfr.Cluster.Fixtures, :take_estate, [athanor.id, "first_need"]) do
              {:ok, taken} -> taken
              _busy -> false
            end
          end,
          "the dead member's estate claim never became takeable",
          @lease_ms * 2
        )

      past_lease_ms = NaiveDateTime.diff(Observer.now(), lease_until, :millisecond)

      Wait.report("a successor's wait past a dead member's lease", past_lease_ms, @ask_bound_ms)

      assert past_lease_ms >= 0,
             "the peer took the estate #{-past_lease_ms} ms before the lease ran out"

      assert past_lease_ms <= @ask_bound_ms,
             "the peer waited #{past_lease_ms} ms past the lease, more than its own asking interval"

      # The successor is a new owner at a raised fence, not the dead
      # member's claim resumed: the owner is boot-scoped, so even the same
      # node coming back is a successor.
      assert answer.owner != claim.owner
      assert answer.fence > claim.fence
    end
  end
end
