# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.KeysTest do
  @moduledoc """
  The worker root is the configured `:worker_key` when one is set, and 32
  random bytes of this boot's own otherwise; every key CYFR issues derives
  from it.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Execution.Keys
  alias Cyfr.WorkerAuth

  setup do
    previous = Keys.root()
    configured = Application.get_env(:cyfr, :worker_key)

    on_exit(fn ->
      Application.put_env(:cyfr, :worker_key, previous)
      Keys.mint()

      if configured,
        do: Application.put_env(:cyfr, :worker_key, configured),
        else: Application.delete_env(:cyfr, :worker_key)
    end)

    :ok
  end

  test "a configured worker key is the root every key derives from" do
    root = :crypto.strong_rand_bytes(32)
    Application.put_env(:cyfr, :worker_key, root)

    assert Keys.mint() == root
    assert Keys.root() == root
    assert Keys.assign_key() == WorkerAuth.assign_key(root)
    assert Keys.worker_key("wrk_1") == WorkerAuth.worker_key(root, "wrk_1")
  end

  test "without one, each boot mints a root of its own" do
    Application.delete_env(:cyfr, :worker_key)

    first = Keys.mint()
    second = Keys.mint()

    assert byte_size(first) == 32 and byte_size(second) == 32
    refute first == second
    assert Keys.root() == second
  end
end
