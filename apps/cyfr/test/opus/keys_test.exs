# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.KeysTest do
  @moduledoc """
  The worker root is the configured `:locus_runtime_root` when one is set, and 32
  random bytes of this boot's own otherwise; every key CYFR issues derives
  from it. Keys are issued under the control plane's generation, `1` for a
  boot that claims none, and under no generation when the control plane
  cannot answer one.
  """

  use ExUnit.Case, async: false

  alias Opus.Keys
  alias Prima.WorkerAuth

  # Where `Arca.ControlPlane` keeps the generation this member recorded.
  @generation_key {Arca.ControlPlane, :generation}

  setup do
    previous = Keys.root()
    configured = Application.get_env(:cyfr, :locus_runtime_root)
    generation = :persistent_term.get(@generation_key, :absent)

    on_exit(fn ->
      Application.put_env(:cyfr, :locus_runtime_root, previous)
      Keys.mint()

      if configured,
        do: Application.put_env(:cyfr, :locus_runtime_root, configured),
        else: Application.delete_env(:cyfr, :locus_runtime_root)

      if generation == :absent,
        do: :persistent_term.erase(@generation_key),
        else: :persistent_term.put(@generation_key, generation)
    end)

    :ok
  end

  test "a configured worker key is the root every key derives from" do
    root = :crypto.strong_rand_bytes(32)
    Application.put_env(:cyfr, :locus_runtime_root, root)

    assert Keys.mint() == root
    assert Keys.root() == root
    assert Keys.assign_key() == WorkerAuth.assign_key(root)
    assert Keys.locus_runtime_key("wrk_1") == WorkerAuth.worker_key(root, "wrk_1")
  end

  test "the generation is the claim's, 1 without a claim, and refused when it is unknown" do
    claim = Application.fetch_env(:arca, :control_plane_claim_enabled)

    on_exit(fn ->
      case claim do
        {:ok, value} -> Application.put_env(:arca, :control_plane_claim_enabled, value)
        :error -> Application.delete_env(:arca, :control_plane_claim_enabled)
      end
    end)

    :ok = Arca.ControlPlane.record_generation(7)
    assert {:ok, 7} = Keys.generation()

    :ok = Arca.ControlPlane.record_generation(:none)
    assert {:ok, 1} = Keys.generation()

    # A member that claims the control plane and has recorded no
    # generation cannot say which it holds.
    :ok = Arca.ControlPlane.forget_generation()
    Application.put_env(:arca, :control_plane_claim_enabled, true)
    assert {:error, :unavailable} = Keys.generation()
  end

  test "the generation is read from the cell's cached standing, at no query" do
    # Every assignment issued and every host call verified reads this, so
    # it must stay a term read. `Arca.ControlPlane` answers it from a
    # persistent term; nothing on this path may put a query behind it.
    :ok = Arca.ControlPlane.record_generation(:none)
    assert {:ok, 1} = Arca.Test.QueryCounter.assert_queries(0, fn -> Keys.generation() end)

    :ok = Arca.ControlPlane.record_generation(9)
    assert {:ok, 9} = Arca.Test.QueryCounter.assert_queries(0, fn -> Keys.generation() end)
  end

  test "without one, each boot mints a root of its own" do
    Application.delete_env(:cyfr, :locus_runtime_root)

    first = Keys.mint()
    second = Keys.mint()

    assert byte_size(first) == 32 and byte_size(second) == 32
    refute first == second
    assert Keys.root() == second
  end
end
