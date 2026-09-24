# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.RatesTest do
  @moduledoc """
  The consented rate as the execution plane asks for it: a cap and a
  window read out of consent, a claim in the row the cell shares, and a
  refusal for every way the answer can fail to be "admitted".

  A bucket's window is a shared, cross-node row, so every case here works
  under an athanor and bucket nothing else claims in and measures its own
  delta. An absolute over the table, or a well-known athanor other files
  also run under, would assert the order the suite happened to run in.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.Schemas.RateWindow
  alias Crucible.Rates

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Arca.Cache.init()

    {:ok,
     actor: Prima.Actor.in_athanor("ath_rates_#{System.unique_integer([:positive])}"),
     bucket: "local.test-component:1.0.0",
     now: DateTime.utc_now()}
  end

  defp policy(requests, window), do: %{rate_limit: %{requests: requests, window: window}}

  defp row(%Prima.Actor{athanor_id: athanor_id}, bucket) do
    Arca.Repo.one(
      from(w in RateWindow, where: w.athanor_id == ^athanor_id and w.bucket == ^bucket)
    )
  end

  defp at(now, ms), do: DateTime.add(now, ms, :millisecond)

  # Run `fun` in `n` processes released together, so the claims really
  # race for the row rather than trickling in as the tasks spawn.
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

  describe "check/3" do
    test "admits under the limit and refuses over it", %{actor: actor, bucket: bucket} do
      assert {:ok, 2} = Rates.check(actor, bucket, policy(3, "1m"))
      assert {:ok, 1} = Rates.check(actor, bucket, policy(3, "1m"))
      assert {:ok, 0} = Rates.check(actor, bucket, policy(3, "1m"))

      assert {:error, :rate_limited, retry_after} = Rates.check(actor, bucket, policy(3, "1m"))
      assert is_integer(retry_after) and retry_after > 0
    end

    test "no configured limit claims nothing at all", %{actor: actor, bucket: bucket} do
      assert {:ok, :unlimited} = Rates.check(actor, bucket, nil)
      assert {:ok, :unlimited} = Rates.check(actor, bucket, %{})
      assert {:ok, :unlimited} = Rates.check(actor, bucket, %{rate_limit: nil})

      assert row(actor, bucket) == nil
    end

    @tag :capture_log
    test "a consented limit that cannot be read is denied, never defaulted", %{
      actor: actor,
      bucket: bucket
    } do
      # Substituting a window would silently rescale an enforcement value
      # the caller consented to.
      assert {:error, :rate_limited, 0} = Rates.check(actor, bucket, policy(10, "every friday"))

      # A window of zero holds nothing and a negative count admits
      # nothing: both read as configured and enforce nothing.
      assert {:error, :rate_limited, 0} = Rates.check(actor, bucket, policy(10, 0))
      assert {:error, :rate_limited, 0} = Rates.check(actor, bucket, policy(-1, "1m"))

      assert row(actor, bucket) == nil
    end

    test "every window format the duration grammar spells", %{actor: actor, bucket: bucket} do
      for window <- ["100ms", "30s", "5m", "1h", 250] do
        assert {:ok, 9} = Rates.check(actor, "#{bucket}:#{inspect(window)}", policy(10, window))
      end
    end

    test "athanors and buckets each keep their own allowance", %{bucket: bucket} do
      mine = Prima.Actor.in_athanor("ath_rates_mine_#{System.unique_integer([:positive])}")
      theirs = Prima.Actor.in_athanor("ath_rates_theirs_#{System.unique_integer([:positive])}")

      assert {:ok, 0} = Rates.check(mine, bucket, policy(1, "1m"))
      assert {:error, :rate_limited, _} = Rates.check(mine, bucket, policy(1, "1m"))

      # Another tenant's window, and another bucket of the same tenant's,
      # are untouched.
      assert {:ok, 0} = Rates.check(theirs, bucket, policy(1, "1m"))
      assert {:ok, 0} = Rates.check(mine, bucket <> ":other", policy(1, "1m"))
    end

    test "a Prima.Limits struct is a limit source like any other", %{
      actor: actor,
      bucket: bucket
    } do
      limits = %Prima.Limits{
        timeout: "30s",
        max_memory_bytes: 64 * 1024 * 1024,
        max_request_size: 1_048_576,
        max_response_size: 5_242_880,
        rate_limit: %{requests: 5, window: "1m"},
        max_concurrent_tasks: 10,
        batch_timeout: "5m"
      }

      assert {:ok, 4} = Rates.check(actor, bucket, limits)
    end
  end

  describe "the window" do
    test "a claim at a boundary is refused while the window before was full", %{
      actor: actor,
      bucket: bucket,
      now: now
    } do
      assert {:ok, 0} = Rates.claim_at(actor, bucket, policy(1, "1s"), now)

      # The instant the next fixed window opens: a counter that only reset
      # would admit here.
      assert {:error, :rate_limited, _} =
               Rates.claim_at(actor, bucket, policy(1, "1s"), at(now, 1_000))

      assert {:ok, 0} = Rates.claim_at(actor, bucket, policy(1, "1s"), at(now, 1_001))
    end

    test "a full window's count is still counted, weighted, in the next", %{
      actor: actor,
      bucket: bucket,
      now: now
    } do
      for _ <- 1..10, do: assert({:ok, _} = Rates.claim_at(actor, bucket, policy(10, "1s"), now))

      admitted =
        for _ <- 1..8, do: Rates.claim_at(actor, bucket, policy(10, "1s"), at(now, 1_500))

      assert Enum.count(admitted, &match?({:ok, _}, &1)) == 5
    end
  end

  describe "nothing in this boot holds an allowance" do
    test "there is no table and no owner process to lose" do
      # The window used to live in this boot's ETS table, behind a named
      # owner: a restart forgot every bucket and handed each a fresh
      # window. Both are gone, and the row is what a claim reads.
      assert :ets.whereis(:cyfr_execution_rates) == :undefined
      assert GenServer.whereis(Crucible.Rates) == nil
    end

    test "a claim outlives the process that made it", %{actor: actor, bucket: bucket} do
      parent = self()

      claimer =
        spawn(fn ->
          send(parent, {:claimed, Rates.check(actor, bucket, policy(3, "1m"))})
          Process.sleep(:infinity)
        end)

      assert_receive {:claimed, {:ok, 2}}, 5_000
      Process.exit(claimer, :kill)

      # Nothing died with it: the count is the row's, and the next claim
      # in any process continues from it.
      assert %RateWindow{count: 1} = row(actor, bucket)
      assert {:ok, 1, 2, 60_000} = Rates.status(actor, bucket, policy(3, "1m"))
      assert {:ok, 1} = Rates.check(actor, bucket, policy(3, "1m"))
    end

    test "callers racing one bucket admit the cap between them and no more", %{
      actor: actor,
      bucket: bucket
    } do
      cap = 8
      results = race(16, fn _i -> Rates.check(actor, bucket, policy(cap, "1m")) end)

      admitted = Enum.count(results, &match?({:ok, _}, &1))

      assert admitted <= cap, "#{admitted} admitted against a cap of #{cap}"
      assert admitted > 0
      assert %RateWindow{count: ^admitted} = row(actor, bucket)

      # Every result is a verdict of this module's vocabulary.
      for result <- results do
        assert match?({:ok, _}, result) or match?({:error, :rate_limited, _}, result) or
                 result == {:error, :unavailable}
      end
    end
  end

  describe "status/3 and reset/2" do
    test "status reads the window and counts nothing", %{actor: actor, bucket: bucket} do
      assert {:ok, 0, 5, 60_000} = Rates.status(actor, bucket, policy(5, "1m"))

      for _ <- 1..2, do: assert({:ok, _} = Rates.check(actor, bucket, policy(5, "1m")))

      assert {:ok, 2, 3, 60_000} = Rates.status(actor, bucket, policy(5, "1m"))
      assert {:ok, 2, 3, 60_000} = Rates.status(actor, bucket, policy(5, "1m"))
    end

    test "status of an unlimited bucket, and of one whose limit cannot be read", %{
      actor: actor,
      bucket: bucket
    } do
      assert {:ok, :unlimited} = Rates.status(actor, bucket, nil)
      assert {:ok, 0, 0, 0} = Rates.status(actor, bucket, policy(10, "every friday"))
    end

    test "reset forgets the bucket's window", %{actor: actor, bucket: bucket} do
      for _ <- 1..2, do: assert({:ok, _} = Rates.check(actor, bucket, policy(2, "1m")))
      assert {:error, :rate_limited, _} = Rates.check(actor, bucket, policy(2, "1m"))

      assert :ok = Rates.reset(actor, bucket)
      assert row(actor, bucket) == nil

      assert {:ok, 1} = Rates.check(actor, bucket, policy(2, "1m"))
    end
  end

  describe "refusals stay apart" do
    @tag :capture_log
    test "an unresolved athanor is refused before any claim", %{bucket: bucket} do
      for actor <- [%Prima.Actor{athanor_id: nil}, %Prima.Actor{athanor_id: ""}] do
        assert {:error, :missing_tenant} = Rates.check(actor, bucket, policy(10, "1m"))
        assert {:error, :missing_tenant} = Rates.status(actor, bucket, policy(10, "1m"))
        assert {:error, :missing_tenant} = Rates.reset(actor, bucket)

        # Even with no limit to enforce: a bucket without a tenant would
        # collide across tenants.
        assert {:error, :missing_tenant} = Rates.check(actor, bucket, nil)
      end
    end

    @tag :capture_log
    test "a store that cannot answer denies, and says so as itself", %{
      actor: actor,
      bucket: bucket
    } do
      assert {:ok, 4} = Rates.check(actor, bucket, policy(5, "1m"))

      # Inside this test's transaction, and rolled back with it.
      Arca.Repo.query!("DROP TABLE rate_windows")

      assert {:error, :unavailable} = Rates.check(actor, bucket, policy(5, "1m"))
      assert {:error, :unavailable} = Rates.status(actor, bucket, policy(5, "1m"))
      assert {:error, :unavailable} = Rates.reset(actor, bucket)

      # An unlimited bucket asks the store nothing, so it still answers.
      assert {:ok, :unlimited} = Rates.check(actor, bucket, nil)
    end
  end
end
