# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.RateWindowsTest do
  @moduledoc """
  The consented rate, claimed in the row the cell shares: two adjacent
  windows weighted at the boundary, a compare-and-set that lets two
  members increment one count only once, and a refusal whenever the row
  cannot be read.

  `rate_windows` is shared, cross-node, node-global state, so every case
  here works under an athanor and bucket nothing else writes and measures
  its own delta. An absolute over the table, or a well-known athanor
  thirty other files also claim in, would make a case assert the order the
  suite happened to run in rather than anything about this code.
  """

  # Sixteen members race one bucket, which on SQLite is sixteen claims
  # queueing on one connection for as long as it takes; a neighbouring
  # case's write would be told the database is busy, so this one runs
  # alone.
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.RateWindows
  alias Arca.Schemas.RateWindow

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    {:ok,
     actor: Arca.Test.Actor.in_athanor("ath_rw_#{System.unique_integer([:positive])}"),
     bucket: "bucket-#{System.unique_integer([:positive])}",
     now: DateTime.utc_now()}
  end

  defp row(%Prima.Actor{athanor_id: athanor_id}, bucket) do
    Arca.Repo.one(
      from(w in RateWindow, where: w.athanor_id == ^athanor_id and w.bucket == ^bucket)
    )
  end

  defp at(now, ms), do: DateTime.add(now, ms, :millisecond)

  # Run `fun` in `n` processes released together: every caller reports
  # ready and spins on one shared flag, so a single write releases them
  # all in the same instant and the claims really race for the row.
  defp race(n, fun) do
    parent = self()
    gate = :atomics.new(1, [])

    tasks =
      for i <- 1..n do
        Task.async(fn ->
          send(parent, {:ready, self()})
          spin_until_open(gate)
          fun.(i)
        end)
      end

    for _ <- 1..n do
      receive do
        {:ready, _pid} -> :ok
      after
        5_000 -> flunk("a racing caller never became ready")
      end
    end

    :atomics.put(gate, 1, 1)
    Task.await_many(tasks, 30_000)
  end

  defp spin_until_open(gate) do
    if :atomics.get(gate, 1) == 0, do: spin_until_open(gate)
  end

  describe "the window" do
    test "the first claim opens it and the cap is what it admits", %{
      actor: actor,
      bucket: bucket
    } do
      assert {:ok, 2} = RateWindows.claim(actor, bucket, 3, 60_000)
      assert {:ok, 1} = RateWindows.claim(actor, bucket, 3, 60_000)
      assert {:ok, 0} = RateWindows.claim(actor, bucket, 3, 60_000)
      assert {:refused, retry} = RateWindows.claim(actor, bucket, 3, 60_000)

      assert retry > 0 and retry <= 2 * 60_000

      assert %RateWindow{count: 3, prior_count: 0, window_ms: 60_000} = row(actor, bucket)
    end

    test "a cap of zero admits nothing and writes nothing", %{actor: actor, bucket: bucket} do
      assert {:refused, 1_000} = RateWindows.claim(actor, bucket, 0, 1_000)
      assert row(actor, bucket) == nil
    end

    test "a full window's count carries into the next one by what is left of it", %{
      actor: actor,
      bucket: bucket,
      now: now
    } do
      for _ <- 1..10, do: assert({:ok, _} = RateWindows.claim_at(actor, bucket, 10, 1_000, now))

      # Halfway through the next window half the prior window is still in
      # view, so half the cap is what it admits.
      admitted =
        for _ <- 1..8,
            do: RateWindows.claim_at(actor, bucket, 10, 1_000, at(now, 1_500))

      assert Enum.count(admitted, &match?({:ok, _}, &1)) == 5
      assert Enum.count(admitted, &match?({:refused, _}, &1)) == 3

      assert %RateWindow{count: 5, prior_count: 10} = row(actor, bucket)
    end

    test "two widths on, nothing the row holds is still in view", %{
      actor: actor,
      bucket: bucket,
      now: now
    } do
      for _ <- 1..10, do: assert({:ok, _} = RateWindows.claim_at(actor, bucket, 10, 1_000, now))

      assert {:ok, 9} = RateWindows.claim_at(actor, bucket, 10, 1_000, at(now, 2_000))
      assert %RateWindow{count: 1, prior_count: 0} = row(actor, bucket)
    end

    test "a claim at the boundary is refused where a plain fixed window would admit it", %{
      actor: actor,
      bucket: bucket,
      now: now
    } do
      assert {:ok, 0} = RateWindows.claim_at(actor, bucket, 1, 1_000, now)

      # The instant the next fixed window opens: a counter that only reset
      # would admit here, and the window before was full.
      assert {:refused, _} = RateWindows.claim_at(actor, bucket, 1, 1_000, at(now, 1_000))

      # Under-refusing at a boundary is the direction this accepts, and
      # the weight decays: one millisecond in, the claim lands.
      assert {:ok, 0} = RateWindows.claim_at(actor, bucket, 1, 1_000, at(now, 1_001))
    end

    test "retry_after names the instant the estimate falls back under the cap", %{
      actor: actor,
      bucket: bucket,
      now: now
    } do
      assert {:ok, 0} = RateWindows.claim_at(actor, bucket, 1, 1_000, now)

      # 600 ms of this window are left, and the next admits one
      # millisecond in, once the prior count has decayed at all.
      assert {:refused, 601} = RateWindows.claim_at(actor, bucket, 1, 1_000, at(now, 400))

      refused_until = at(now, 400 + 601)
      assert {:refused, _} = RateWindows.claim_at(actor, bucket, 1, 1_000, at(now, 1_000))
      assert {:ok, 0} = RateWindows.claim_at(actor, bucket, 1, 1_000, refused_until)
    end

    test "a claim of another width opens a window at its own", %{
      actor: actor,
      bucket: bucket,
      now: now
    } do
      for _ <- 1..3, do: assert({:ok, _} = RateWindows.claim_at(actor, bucket, 3, 1_000, now))
      assert {:refused, _} = RateWindows.claim_at(actor, bucket, 3, 1_000, now)

      # A count taken under one width is never rescaled to another: the
      # consent changed, so the window it is counted in changes with it.
      assert {:ok, 2} = RateWindows.claim_at(actor, bucket, 3, 5_000, now)
      assert %RateWindow{window_ms: 5_000, count: 1, prior_count: 0} = row(actor, bucket)
    end

    test "estimate reads the weighted count and counts nothing", %{
      actor: actor,
      bucket: bucket
    } do
      assert {:ok, 0, 5, 60_000} = RateWindows.estimate(actor, bucket, 5, 60_000)

      for _ <- 1..2, do: assert({:ok, _} = RateWindows.claim(actor, bucket, 5, 60_000))

      assert {:ok, 2, 3, 60_000} = RateWindows.estimate(actor, bucket, 5, 60_000)
      assert {:ok, 2, 3, 60_000} = RateWindows.estimate(actor, bucket, 5, 60_000)
      assert %RateWindow{count: 2} = row(actor, bucket)
    end

    test "clear forgets the window and the next claim opens a fresh one", %{
      actor: actor,
      bucket: bucket
    } do
      for _ <- 1..2, do: assert({:ok, _} = RateWindows.claim(actor, bucket, 2, 60_000))
      assert {:refused, _} = RateWindows.claim(actor, bucket, 2, 60_000)

      assert :ok = RateWindows.clear(actor, bucket)
      assert row(actor, bucket) == nil

      assert {:ok, 1} = RateWindows.claim(actor, bucket, 2, 60_000)
    end
  end

  describe "two members, one bucket" do
    # Nothing in a boot holds an allowance any more, so sixteen processes
    # claiming one bucket are sixteen members claiming it: the row is the
    # only thing between them, and it is what this asserts.
    test "sixteen claiming at once admit the cap between them and no more", %{
      actor: actor,
      bucket: bucket
    } do
      cap = 8
      results = race(16, fn _i -> RateWindows.claim(actor, bucket, cap, 60_000) end)

      admitted = Enum.count(results, &match?({:ok, _}, &1))
      refused = Enum.count(results, &match?({:refused, _}, &1))
      unsettled = Enum.count(results, &match?({:error, :contended}, &1))

      assert admitted + refused + unsettled == 16
      assert admitted <= cap, "#{admitted} admitted against a cap of #{cap}"
      assert admitted > 0

      # The row counted every claim that was admitted and nothing else: no
      # two claims incremented from the same count, and a claim the row
      # would not settle refused rather than admitting on a count it never
      # wrote.
      assert %RateWindow{count: ^admitted} = row(actor, bucket)
    end

    test "a claimer that dies leaves its claim counted, because the row holds it", %{
      actor: actor,
      bucket: bucket
    } do
      parent = self()

      claimer =
        spawn(fn ->
          send(parent, {:claimed, RateWindows.claim(actor, bucket, 3, 60_000)})
          Process.sleep(:infinity)
        end)

      assert_receive {:claimed, {:ok, 2}}, 5_000
      Process.exit(claimer, :kill)

      assert %RateWindow{count: 1} = row(actor, bucket)
      assert {:ok, 1} = RateWindows.claim(actor, bucket, 3, 60_000)
    end
  end

  describe "the tenant" do
    test "two athanors claiming one bucket name keep their own windows", %{bucket: bucket} do
      mine = Arca.Test.Actor.in_athanor("ath_rw_mine_#{System.unique_integer([:positive])}")
      theirs = Arca.Test.Actor.in_athanor("ath_rw_theirs_#{System.unique_integer([:positive])}")

      assert {:ok, 0} = RateWindows.claim(mine, bucket, 1, 60_000)
      assert {:refused, _} = RateWindows.claim(mine, bucket, 1, 60_000)

      assert {:ok, 0} = RateWindows.claim(theirs, bucket, 1, 60_000)
      assert %RateWindow{count: 1} = row(mine, bucket)
      assert %RateWindow{count: 1} = row(theirs, bucket)
    end

    test "an unresolved athanor is refused before any query", %{bucket: bucket} do
      for actor <- [%Prima.Actor{athanor_id: nil}, %Prima.Actor{athanor_id: ""}] do
        assert {:error, :no_athanor} = RateWindows.claim(actor, bucket, 1, 60_000)
        assert {:error, :no_athanor} = RateWindows.estimate(actor, bucket, 1, 60_000)
        assert {:error, :no_athanor} = RateWindows.clear(actor, bucket)

        assert {:error, :no_athanor} =
                 RateWindows.claim_at(actor, bucket, 1, 60_000, DateTime.utc_now())
      end
    end
  end

  describe "the rows nobody claims" do
    test "a claim that opens a bucket reclaims the athanor's dead windows", %{
      actor: actor,
      now: now
    } do
      dead = "dead-#{System.unique_integer([:positive])}"
      live = "live-#{System.unique_integer([:positive])}"
      fresh = "fresh-#{System.unique_integer([:positive])}"

      assert {:ok, _} = RateWindows.claim_at(actor, dead, 5, 100, now)
      assert {:ok, _} = RateWindows.claim_at(actor, live, 5, 100, at(now, 250))

      # 300 ms on, the first bucket's window and the one after it are both
      # past; the second's prior window is still in view.
      assert {:ok, _} = RateWindows.claim_at(actor, fresh, 5, 100, at(now, 300))

      assert row(actor, dead) == nil
      assert %RateWindow{} = row(actor, live)
      assert %RateWindow{} = row(actor, fresh)
    end

    test "purge_expired takes the dead windows of every width and leaves the live", %{
      actor: actor
    } do
      now = DateTime.utc_now()
      dead_narrow = "dead-narrow-#{System.unique_integer([:positive])}"
      dead_wide = "dead-wide-#{System.unique_integer([:positive])}"
      live = "live-#{System.unique_integer([:positive])}"

      assert {:ok, _} = RateWindows.claim_at(actor, dead_narrow, 5, 100, at(now, -5_000))
      assert {:ok, _} = RateWindows.claim_at(actor, dead_wide, 5, 1_000, at(now, -5_000))
      assert {:ok, _} = RateWindows.claim(actor, live, 5, 60_000)

      # This case's own delta: it counts at least its two, whatever else
      # the cell left behind.
      assert RateWindows.purge_expired() >= 2

      assert row(actor, dead_narrow) == nil
      assert row(actor, dead_wide) == nil
      assert %RateWindow{} = row(actor, live)
    end
  end

  describe "a store that cannot answer" do
    @tag :capture_log
    test "refuses the claim rather than admitting it", %{actor: actor, bucket: bucket} do
      assert {:ok, 4} = RateWindows.claim(actor, bucket, 5, 60_000)

      # Inside this test's transaction, and rolled back with it.
      Arca.Repo.query!("DROP TABLE rate_windows")

      # A ceiling that cannot be read is not a ceiling that passes, and
      # the store's silence is distinguishable from the ceiling's refusal.
      assert {:error, :database_error} = RateWindows.claim(actor, bucket, 5, 60_000)
      assert {:error, :database_error} = RateWindows.estimate(actor, bucket, 5, 60_000)
      assert {:error, :database_error} = RateWindows.clear(actor, bucket)
      assert RateWindows.purge_expired() == 0
    end
  end
end
