# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Test.Wait do
  @moduledoc """
  Poll a condition until it holds, instead of guessing with a fixed sleep.

  A `Process.sleep(n)` that stands in for synchronisation is wrong in both
  directions: too short and it flakes on a loaded machine, long enough to
  be safe and it spends that wall-clock on every green run. Worse, a sleep
  that establishes the very ordering a test asserts can pass for the wrong
  reason — the assertion holds because the sleep put the system in that
  state, not because the code did.

  `wait_until/2` polls every 10 ms and fails at the deadline with a message
  naming what never became true.

  A real deadline is still a deadline: use this for something that becomes
  true on its own (a timer fires, a task finishes, a GenServer settles),
  never to wait for something no other process will do.
  """

  import ExUnit.Assertions

  @poll_ms 10
  @default_timeout_ms 2_000

  @doc """
  Poll `fun` every 10 ms until it returns truthy, flunking after `timeout`.

  `label` names the condition in the failure message; pass one whenever
  the call site is not self-evident.
  """
  @spec wait_until((-> as_boolean(term())), non_neg_integer(), String.t() | nil) :: :ok
  def wait_until(fun, timeout \\ @default_timeout_ms, label \\ nil)
      when is_function(fun, 0) do
    poll(fun, System.monotonic_time(:millisecond) + timeout, timeout, label)
  end

  defp poll(fun, deadline, timeout, label) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("waited #{timeout}ms for #{label || "a condition"}, which never held")

      true ->
        Process.sleep(@poll_ms)
        poll(fun, deadline, timeout, label)
    end
  end
end
