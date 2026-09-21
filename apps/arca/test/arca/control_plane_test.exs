# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ControlPlaneTest do
  @moduledoc """
  The cached standing every gate in the product reads on its way in.

  The record is process-wide, so each case saves what it finds and puts it
  back: the suite's other cases read the same term, and a case that leaves
  its own standing behind would be deciding theirs.
  """

  # Writes the process-wide ownership record and the application's claim
  # switch, so it runs alone and restores both.
  use ExUnit.Case, async: false

  alias Arca.ControlPlane

  @standing_key {Arca.ControlPlane, :standing}
  @generation_key {Arca.ControlPlane, :generation}

  setup do
    standing = :persistent_term.get(@standing_key, :absent)
    generation = :persistent_term.get(@generation_key, :absent)
    claim = Application.get_env(:arca, :control_plane_claim_enabled)

    on_exit(fn ->
      restore(@standing_key, standing)
      restore(@generation_key, generation)
      Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)

    :ok
  end

  describe "the hot path" do
    test "held?/0 answers without a query" do
      :ok = ControlPlane.record({:held, 60_000})

      assert assert_queries(0, fn -> ControlPlane.held?() end)

      # And the same when it answers no, whichever way it gets there.
      :ok = ControlPlane.record(:lost)
      refute assert_queries(0, fn -> ControlPlane.held?() end)

      # The one branch that reads anything outside the record reads the
      # deployment's switch, which is an application key and not a query.
      claimed_here(true)
      :ok = ControlPlane.record(:unclaimed)
      refute assert_queries(0, fn -> ControlPlane.held?() end)
    end

    test "generation/0 answers without a query" do
      :ok = ControlPlane.record_generation(7)
      assert assert_queries(0, fn -> ControlPlane.generation() end) == {:ok, 7}

      :ok = ControlPlane.forget_generation()
      claimed_here(true)
      assert assert_queries(0, fn -> ControlPlane.generation() end) == {:error, :unavailable}
    end
  end

  describe "what a member holds" do
    test "a member that has recorded nothing holds nothing while a claimant runs here" do
      claimed_here(true)
      :ok = ControlPlane.record(:unclaimed)

      refute ControlPlane.held?()
      assert ControlPlane.generation() == {:error, :unavailable}
    end

    test "with no claimant there is no slot to take, so every boot holds and none is fenced" do
      claimed_here(false)
      :ok = ControlPlane.record(:unclaimed)
      :ok = ControlPlane.forget_generation()

      assert ControlPlane.held?()
      assert ControlPlane.generation() == :none
    end

    test "a lapse is not held, whatever the deployment's switch says" do
      :ok = ControlPlane.record(:lost)

      claimed_here(false)
      refute ControlPlane.held?()

      claimed_here(true)
      refute ControlPlane.held?()
    end

    test "an indefinite hold is the one that does not run out" do
      :ok = ControlPlane.record({:held, :indefinitely})
      assert ControlPlane.held?()
    end
  end

  describe "the local clock" do
    test "a hold is a duration counted down, and runs out on its own" do
      :ok = ControlPlane.record({:held, 60})
      assert ControlPlane.held?()

      Process.sleep(100)
      refute ControlPlane.held?()

      # Recording again is how a renewal is heard; nothing else moves it.
      :ok = ControlPlane.record({:held, 60_000})
      assert ControlPlane.held?()
    end

    test "a hold of no time left is already over" do
      :ok = ControlPlane.record({:held, 0})
      refute ControlPlane.held?()
    end

    test "the countdown is monotonic: it is stored as an instant, not a wall time" do
      :ok = ControlPlane.record({:held, 60_000})

      assert {:held, deadline} = :persistent_term.get(@standing_key)
      assert is_integer(deadline)

      # Within a lease of now on the monotonic clock, and far from any
      # value a wall clock in milliseconds would produce.
      left = deadline - System.monotonic_time(:millisecond)
      assert left > 59_000 and left <= 60_000
    end
  end

  describe "the generation" do
    test "a recorded generation is the member's, and forgetting it is not the same as none" do
      claimed_here(true)

      :ok = ControlPlane.record_generation(3)
      assert ControlPlane.generation() == {:ok, 3}

      # A successor's take raises it; nothing else does.
      :ok = ControlPlane.record_generation(4)
      assert ControlPlane.generation() == {:ok, 4}

      :ok = ControlPlane.forget_generation()
      assert ControlPlane.generation() == {:error, :unavailable}

      :ok = ControlPlane.record_generation(:none)
      assert ControlPlane.generation() == :none
    end
  end

  defp claimed_here(enabled),
    do: Application.put_env(:arca, :control_plane_claim_enabled, enabled)

  defp restore(key, :absent), do: :persistent_term.erase(key)
  defp restore(key, value), do: :persistent_term.put(key, value)

  defp assert_queries(n, fun), do: Arca.Test.QueryCounter.assert_queries(n, fun)
end
