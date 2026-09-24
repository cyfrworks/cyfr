# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.KeysTest do
  @moduledoc """
  The worker root is the configured `:worker_key` when one is set, and 32
  random bytes of this boot's own otherwise; every key CYFR issues derives
  from it. Keys are issued under the control plane's generation, `1` for a
  boot that claims none, and under no generation when the control plane
  cannot answer one.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Execution.Keys
  alias Prima.WorkerAuth

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

  test "the generation is the claim's, 1 without a claim, and refused when it is unknown" do
    assert {:ok, 7} = Keys.generation({:ok, 7})
    assert {:ok, 1} = Keys.generation(:none)

    for unknown <- [{:error, :unavailable}, {:error, :database_error}, {:ok, 0}, nil] do
      assert {:error, :unavailable} = Keys.generation(unknown)
    end

    assert {:ok, generation} = Keys.generation()
    assert generation > 0
  end

  test "the generation is read from the cell's cached standing, at no query" do
    # Every assignment issued and every host call verified reads this, so
    # it must stay a term read. `Arca.ControlPlane` answers it from a
    # persistent term; nothing on this path may put a query behind it.
    on_exit(fn -> Arca.ControlPlane.forget_generation() end)

    :ok = Arca.ControlPlane.record_generation(:none)
    assert {:ok, 1} = Arca.Test.QueryCounter.assert_queries(0, fn -> Keys.generation() end)

    :ok = Arca.ControlPlane.record_generation(9)
    assert {:ok, 9} = Arca.Test.QueryCounter.assert_queries(0, fn -> Keys.generation() end)
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
