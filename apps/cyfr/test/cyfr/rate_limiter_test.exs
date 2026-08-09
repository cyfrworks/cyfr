# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RateLimiterTest do
  # Rate-limit counters live in their own table, isolated from Arca.Cache, so an
  # attacker-cardinality flood cannot evict sessions or OAuth state.
  use ExUnit.Case, async: false

  setup do
    Cyfr.RateLimiter.reset()
    on_exit(&Cyfr.RateLimiter.reset/0)
    :ok
  end

  test "allows up to the limit, then denies with a retry-after" do
    key = {:rate_limit, :test, "k1"}

    for _ <- 1..3 do
      assert :ok = Cyfr.RateLimiter.check(key, 3, 60_000)
    end

    assert {:deny, retry_after} = Cyfr.RateLimiter.check(key, 3, 60_000)
    assert retry_after >= 1
  end

  test "distinct keys have independent windows" do
    for _ <- 1..3, do: Cyfr.RateLimiter.check({:rate_limit, :test, "a"}, 3, 60_000)

    assert :ok = Cyfr.RateLimiter.check({:rate_limit, :test, "b"}, 3, 60_000)
  end

  test "a closed window reopens" do
    key = {:rate_limit, :test, "recycle"}
    for _ <- 1..3, do: Cyfr.RateLimiter.check(key, 3, 60_000)
    assert {:deny, _} = Cyfr.RateLimiter.check(key, 3, 60_000)

    # Backdate past the window; the next hit opens a fresh one.
    past = System.monotonic_time(:millisecond) - 90_000
    :ets.insert(Cyfr.RateLimiter.table_name(), {key, 3, past})

    assert :ok = Cyfr.RateLimiter.check(key, 3, 60_000)
  end

  test "counters never touch the Arca.Cache table" do
    before = :ets.info(Arca.Cache.table_name(), :size)

    for i <- 1..50 do
      Cyfr.RateLimiter.check({:rate_limit, :test, "ip-#{i}"}, 1, 60_000)
    end

    # The flood populated Cyfr.RateLimiter, not the shared cache.
    assert :ets.info(Cyfr.RateLimiter.table_name(), :size) >= 50
    assert :ets.info(Arca.Cache.table_name(), :size) == before
  end
end
