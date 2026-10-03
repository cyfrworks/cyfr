# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RateLimiterTest do
  # Rate-limit counters live in their own table, isolated from Arca.Cache, so an
  # attacker-cardinality flood cannot evict sessions or OAuth state.
  #
  # `Prima.RateLimiter` is a shared contract, but this suite stays here:
  # the isolation case below reads `Arca.Cache`'s table, and every case
  # needs the limiter started by Sanctum's application tree.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup do
    Prima.RateLimiter.reset()
    on_exit(&Prima.RateLimiter.reset/0)
    :ok
  end

  test "allows up to the limit, then denies with a retry-after" do
    key = {:rate_limit, :test, "k1"}

    for _ <- 1..3 do
      assert :ok = Prima.RateLimiter.check(key, 3, 60_000)
    end

    assert {:deny, retry_after} = Prima.RateLimiter.check(key, 3, 60_000)
    assert retry_after >= 1
  end

  test "distinct keys have independent windows" do
    for _ <- 1..3, do: Prima.RateLimiter.check({:rate_limit, :test, "a"}, 3, 60_000)

    assert :ok = Prima.RateLimiter.check({:rate_limit, :test, "b"}, 3, 60_000)
  end

  test "a closed window reopens" do
    key = {:rate_limit, :test, "recycle"}
    for _ <- 1..3, do: Prima.RateLimiter.check(key, 3, 60_000)
    assert {:deny, _} = Prima.RateLimiter.check(key, 3, 60_000)

    # Backdate past the window; the next hit opens a fresh one.
    past = System.monotonic_time(:millisecond) - 90_000
    :ets.insert(Prima.RateLimiter.table_name(), {key, 3, past})

    assert :ok = Prima.RateLimiter.check(key, 3, 60_000)
  end

  test "counters never touch the Arca.Cache table" do
    before = :ets.info(Arca.Cache.table_name(), :size)

    for i <- 1..50 do
      Prima.RateLimiter.check({:rate_limit, :test, "ip-#{i}"}, 1, 60_000)
    end

    # The flood populated Prima.RateLimiter, not the shared cache.
    assert :ets.info(Prima.RateLimiter.table_name(), :size) >= 50
    assert :ets.info(Arca.Cache.table_name(), :size) == before
  end

  test "Sanctum owns the single limiter and its unavailable table refuses requests" do
    pid = Process.whereis(Prima.RateLimiter)
    assert is_pid(pid)

    assert {Prima.RateLimiter, pid, :worker, [Prima.RateLimiter]} in Supervisor.which_children(
             Sanctum.Supervisor
           )

    assert {:error, {:already_started, ^pid}} = Prima.RateLimiter.start_link()

    :ok = Supervisor.terminate_child(Sanctum.Supervisor, Prima.RateLimiter)

    try do
      assert capture_log(fn ->
               assert {:deny, 1} = Prima.RateLimiter.check(:unavailable, 1, 1_000)
             end) =~ "table unavailable"
    after
      {:ok, _} = Supervisor.restart_child(Sanctum.Supervisor, Prima.RateLimiter)
    end
  end
end
