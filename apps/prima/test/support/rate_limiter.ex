# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Test.RateLimiter do
  @moduledoc """
  The suite's reset of the node's advisory windows (`Prima.RateLimiter`).
  The table is the node's, so a test that resets it runs synchronously.
  """

  @doc """
  Clear every counter of the running limiter: in Prima's own suite, where a
  case starts one, as under `Sanctum.Supervisor`. Raises `ArgumentError`
  when no limiter's table exists.
  """
  @spec reset!() :: :ok
  def reset! do
    true = :ets.delete_all_objects(Prima.RateLimiter.table_name())
    :ok
  end
end
