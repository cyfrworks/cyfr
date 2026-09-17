# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Test.Wait do
  @moduledoc """
  Poll a condition until it holds, instead of guessing with a fixed sleep:
  `wait_until/3` polls every 10 ms and fails at the deadline with a
  message naming what never became true. For something that becomes true
  on its own (a runner exits, a report arrives), never for something no
  other process will do.
  """

  import ExUnit.Assertions

  @poll_ms 10
  @default_timeout_ms 2_000

  @doc "Poll `fun` every 10 ms until it returns truthy, flunking after `timeout`."
  @spec wait_until((-> as_boolean(term())), non_neg_integer(), String.t() | nil) :: :ok
  def wait_until(fun, timeout \\ @default_timeout_ms, label \\ nil) when is_function(fun, 0) do
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
