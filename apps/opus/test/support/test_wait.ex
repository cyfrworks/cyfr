# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.TestWait do
  @moduledoc """
  Poll a condition until it holds instead of guessing with fixed sleeps.

  Fixed `Process.sleep(n)` waits either flake (n too short on a loaded
  machine) or waste wall-clock (n padded for safety). `wait_until/2` polls
  every 10ms and fails loudly at the deadline.
  """

  import ExUnit.Assertions

  @doc """
  Poll `fun` every 10ms until it returns truthy, flunking after `timeout` ms.
  """
  def wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("wait_until: condition not met within timeout")
      else
        Process.sleep(10)
        poll(fun, deadline)
      end
    end
  end
end
