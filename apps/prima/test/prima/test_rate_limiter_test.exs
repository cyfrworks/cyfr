# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Test.RateLimiterTest do
  @moduledoc """
  `Prima.Test.RateLimiter.reset!/0` empties the running limiter's table.
  """

  # The table is the node's.
  use ExUnit.Case, async: false

  alias Prima.RateLimiter

  setup do
    # Sanctum owns the limiter where it runs; this application's own suite
    # starts none, so the case starts one.
    unless Process.whereis(RateLimiter), do: start_supervised!(RateLimiter)
    :ok
  end

  test "a reset empties the limiter's table, and the next hit opens a fresh window" do
    key = {:test_reset, System.unique_integer([:positive])}

    assert :ok = RateLimiter.check(key, 1, 60_000)
    assert {:deny, _seconds} = RateLimiter.check(key, 1, 60_000)
    assert :ets.info(RateLimiter.table_name(), :size) > 0

    assert :ok = Prima.Test.RateLimiter.reset!()

    assert :ets.info(RateLimiter.table_name(), :size) == 0
    assert :ok = RateLimiter.check(key, 1, 60_000)
  end
end
