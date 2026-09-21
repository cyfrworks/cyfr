# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.JobClaimsTest do
  @moduledoc """
  The cell's singleton jobs: one row per `(kind, key)`, taken at a new
  fence, held against another member while its lease stands, taken over
  once it ran out — and written only by the owner and fence it still
  reads.

  `job_claims` is shared, cross-node, node-global state, so every case
  here works under a key nothing else uses and measures its own delta.
  An absolute count over the table, or a well-known key another file also
  writes, would make a case assert the order the suite happened to run
  in rather than anything about this code.
  """

  # Eight members race one claim row. On SQLite that is eight write
  # transactions queueing on one lock for as long as the busy timeout
  # allows, which is long enough that a neighbouring case's write is told
  # the database is busy — so this one runs alone.
  use ExUnit.Case, async: false

  import Cyfr.Test.Wait
  import Ecto.Query

  alias Arca.JobClaims
  alias Arca.Schemas.JobClaim

  @lease_ms 60_000

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    {:ok, key: "svc-#{System.unique_integer([:positive])}"}
  end

  defp watch(key, owner, lease_ms \\ @lease_ms),
    do: JobClaims.claim("worker_watch", key, owner, lease_ms)

  # A claim with a lease this short has run out by the time anyone looks.
  defp lapsed!(key, owner) do
    {:ok, claim} = watch(key, owner, 1)
    wait_until(fn -> not JobClaims.live?(claim) end, 2_000, "the lease to run out")
    claim
  end

  defp rows(key), do: Arca.Repo.aggregate(from(c in JobClaim, where: c.key == ^key), :count)

  describe "taking the row" do
    test "one member holds it while its lease stands, and the next is told it is busy", %{
      key: key
    } do
      before = rows(key)

      assert {:ok, %JobClaim{owner: "boot_a", fence: 1} = held} = watch(key, "boot_a")
      assert JobClaims.live?(held)

      assert {:busy, busy} = watch(key, "boot_b")
      assert busy.owner == "boot_a"
      assert busy.fence == 1

      # Asking again is how a member holds through its tick, so its own
      # live claim answers itself and raises nothing.
      assert {:ok, ^held} = watch(key, "boot_a")

      # This case's own delta: one row, whatever the table held before.
      assert rows(key) - before == 1
    end

    test "past the lease the next member takes it and the fence rises", %{key: key} do
      lapsed = lapsed!(key, "boot_a")

      assert {:ok, taken} = watch(key, "boot_b")
      assert taken.owner == "boot_b"
      assert taken.fence == lapsed.fence + 1
      assert JobClaims.live?(taken)
      assert rows(key) == 1
    end

    test "the same key under another kind is another job", %{key: key} do
      assert {:ok, _} = watch(key, "boot_a")
      assert {:ok, other} = JobClaims.claim("seed_release", key, "boot_b", @lease_ms)
      assert other.fence == 1
      assert rows(key) == 2
    end

    test "a kind the schema does not name is a caller's bug, not a silent pass", %{key: key} do
      assert_raise ArgumentError, fn -> JobClaims.claim("whenever", key, "boot_a", @lease_ms) end
      assert_raise ArgumentError, fn -> JobClaims.read("whenever", key) end
      assert rows(key) == 0
    end

    test "of several members claiming at once, one wins and the rest are told who holds it", %{
      key: key
    } do
      results =
        1..8
        |> Task.async_stream(fn n -> watch(key, "boot_#{n}") end,
          max_concurrency: 8,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
      assert winner.fence == 1

      losers = for {:busy, claim} <- results, do: claim
      assert length(losers) == 7

      # Every loser is told the same holder, so none of them has a reason
      # to act and none of them is left guessing.
      assert Enum.all?(losers, &(&1.owner == winner.owner and &1.fence == winner.fence))
      assert rows(key) == 1
    end
  end

  describe "the two ways to lose" do
    test "a renew after a takeover is :taken, and it resurrects nothing", %{key: key} do
      stale = lapsed!(key, "boot_a")
      {:ok, taken} = watch(key, "boot_b")

      assert :taken = JobClaims.renew(stale, @lease_ms)
      assert :taken = JobClaims.record(stale, "boot_a was here")
      assert :taken = JobClaims.release(stale)

      assert {:ok, unchanged} = JobClaims.read("worker_watch", key)
      assert unchanged.owner == "boot_b"
      assert unchanged.fence == taken.fence
      assert unchanged.lease_until == taken.lease_until
      assert unchanged.detail == nil
    end

    test "a renew whose own lease ran out first is :lapsed, and the row is still there to ask for",
         %{key: key} do
      lapsed = lapsed!(key, "boot_a")

      # Nobody has taken it: the holder was only too slow, which is the
      # answer that means ask again rather than stop.
      assert :lapsed = JobClaims.renew(lapsed, @lease_ms)

      assert {:ok, untouched} = JobClaims.read("worker_watch", key)
      assert untouched.owner == "boot_a"
      assert untouched.fence == lapsed.fence

      # And asking again wins it back, one fence up.
      assert {:ok, again} = watch(key, "boot_a")
      assert again.fence == lapsed.fence + 1
      assert JobClaims.live?(again)
    end

    test "a release by a member that no longer holds the fence changes nothing", %{key: key} do
      {:ok, held} = watch(key, "boot_a")
      {:ok, renewed} = JobClaims.renew(held, @lease_ms)
      assert renewed.fence == held.fence + 1

      # The row this caller read is two writes ago; its release is refused
      # and the live lease stands.
      assert :taken = JobClaims.release(held)
      assert {:ok, standing} = JobClaims.read("worker_watch", key)
      assert standing.fence == renewed.fence
      assert JobClaims.live?(standing)

      # Released at the fence it does hold, the row is takeable at once
      # and its owner is still on it.
      assert :ok = JobClaims.release(renewed)
      assert {:ok, given_up} = JobClaims.read("worker_watch", key)
      refute JobClaims.live?(given_up)
      assert given_up.owner == "boot_a"
    end
  end

  describe "the evidence a successor inherits" do
    test "detail written by the winner is what the next taker reads", %{key: key} do
      {:ok, held} = watch(key, "boot_a", 1)
      assert {:ok, noted} = JobClaims.record(held, ~s({"misses":2}))
      assert noted.detail == ~s({"misses":2})
      assert noted.fence == held.fence + 1

      wait_until(fn -> not JobClaims.live?(noted) end, 2_000, "the lease to run out")

      # The takeover moves the owner and the fence and leaves the evidence
      # alone, which is what lets a miss count survive a rotation instead
      # of restarting and never reaching its threshold.
      assert {:ok, successor} = watch(key, "boot_b")
      assert successor.owner == "boot_b"
      assert successor.fence == noted.fence + 1
      assert successor.detail == ~s({"misses":2})

      # And the successor writes its own over it.
      assert {:ok, reset} = JobClaims.record(successor, ~s({"misses":0}))
      assert reset.detail == ~s({"misses":0})
    end

    test "recording writes evidence under the fence without extending the lease", %{key: key} do
      {:ok, held} = watch(key, "boot_a")

      assert {:ok, noted} = JobClaims.record(held, "one miss")
      assert noted.lease_until == held.lease_until
      assert noted.fence == held.fence + 1

      # A stale copy of the row cannot write over it: every write raises
      # the fence, so the holder carries the row it last wrote.
      assert :taken = JobClaims.record(held, "two misses")
      assert {:ok, %{detail: "one miss"}} = JobClaims.read("worker_watch", key)
    end

    test "a renew carries the evidence in the same write as the lease", %{key: key} do
      {:ok, held} = watch(key, "boot_a")

      assert {:ok, renewed} = JobClaims.renew(held, @lease_ms, detail: "heard")
      assert renewed.detail == "heard"
      assert DateTime.compare(renewed.lease_until, held.lease_until) == :gt

      # Omitted, it is kept rather than cleared: a renewal is not an
      # erasure of what the job knows.
      assert {:ok, again} = JobClaims.renew(renewed, @lease_ms)
      assert again.detail == "heard"

      # And an explicit nil does clear it.
      assert {:ok, cleared} = JobClaims.renew(again, @lease_ms, detail: nil)
      assert cleared.detail == nil
    end

    test "a claim that has never been written has no evidence and reads as absent", %{key: key} do
      assert {:error, :not_found} = JobClaims.read("worker_watch", key)
      assert {:ok, %{detail: nil}} = watch(key, "boot_a")
    end
  end
end
