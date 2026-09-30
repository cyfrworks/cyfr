# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.RateLimiterTest do
  @moduledoc """
  The node's advisory windows: `check/3` counts a hit and refuses at the
  cap; `peek/3` answers what `check/3` would at the cap and never counts,
  opens or moves a window.
  """

  # The table is the node's, and `reset/0` clears it for everyone.
  use ExUnit.Case, async: false

  alias Prima.RateLimiter

  setup do
    # Sanctum owns the limiter where it runs; this application's own suite
    # starts none, so the case starts one.
    unless Process.whereis(RateLimiter), do: start_supervised!(RateLimiter)
    RateLimiter.reset()
    on_exit(fn -> RateLimiter.reset() end)
    :ok
  end

  defp key, do: {:peek_test, System.unique_integer([:positive])}
  defp counted(key), do: :ets.lookup(RateLimiter.table_name(), key)

  describe "peek/3" do
    test "a key never counted has room, and peeking opens no window" do
      key = key()

      for _ <- 1..10, do: assert(RateLimiter.peek(key, 3, 60_000) == :ok)
      assert counted(key) == []

      # The first hit after the peeks is still the window's first.
      assert RateLimiter.check(key, 1, 60_000) == :ok
      assert [{^key, 1, _start}] = counted(key)
    end

    test "under the cap it has room, and the count does not move" do
      key = key()
      :ok = RateLimiter.check(key, 3, 60_000)
      :ok = RateLimiter.check(key, 3, 60_000)
      before = counted(key)

      for _ <- 1..10, do: assert(RateLimiter.peek(key, 3, 60_000) == :ok)
      assert counted(key) == before

      # The one hit left is still there for the caller that counts.
      assert RateLimiter.check(key, 3, 60_000) == :ok
      assert {:deny, _} = RateLimiter.check(key, 3, 60_000)
    end

    test "at the cap it refuses with the time left, as check/3 does, counting nothing" do
      key = key()
      for _ <- 1..3, do: :ok = RateLimiter.check(key, 3, 60_000)
      [{^key, 3, _start}] = before = counted(key)

      assert {:deny, retry_after_s} = RateLimiter.peek(key, 3, 60_000)
      assert retry_after_s in 1..60
      assert {:deny, _retry_after_s} = RateLimiter.check(key, 3, 60_000)

      for _ <- 1..10, do: RateLimiter.peek(key, 3, 60_000)
      assert counted(key) == before
    end

    test "a window that closed has room again, and stays as it was" do
      key = key()
      :ok = RateLimiter.check(key, 1, 1)
      before = counted(key)
      Process.sleep(5)

      assert RateLimiter.peek(key, 1, 1) == :ok
      assert counted(key) == before
    end
  end
end
