# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.SlotsTest do
  @moduledoc """
  The execution slots CYFR boots: one `Prima.Slots` instance named
  `Crucible.Slots` under the infra tier, on the caps the operator
  configured, keyed by athanor, with a child reserve the authority depth
  cap fits inside, and the boot warning that says when one athanor's
  roots can fill the node.
  """

  # async: false — reads live application config and fills the live
  # instance.
  use ExUnit.Case, async: false

  import Prima.Test.Wait

  alias Prima.Slots

  @slots Crucible.Slots

  test "the instance runs on the configured caps, as the infra tier's child" do
    {max, key_max} = Cyfr.Application.execution_slot_caps()

    assert max == Application.get_env(:cyfr, :crucible_max_concurrent, Slots.default_max())

    assert key_max ==
             Application.get_env(
               :cyfr,
               :crucible_max_concurrent_per_tenant,
               Slots.default_key_max()
             )

    assert %{max: ^max, key_max: ^key_max, child_reserve: reserve} = Slots.status(@slots)
    assert reserve == Slots.child_reserve(max)

    assert {@slots, pid, :worker, [Prima.Slots]} =
             Cyfr.InfraSupervisor |> Supervisor.which_children() |> List.keyfind(@slots, 0)

    assert pid == Process.whereis(@slots)
  end

  # A parent holds its execution slot while blocking on a child, so a
  # chain deeper than the slots a child can always reach would self-
  # deadlock — a denial reachable from one guest. Children take the child
  # reserve (never the athanor's cap), so the Authority depth cap must sit
  # within that reserve, for the shipped default and for whatever this
  # deployment configures. If this test is red, the configuration is unsafe
  # (or the cap grew); do not weaken the assertion.
  test "the authority depth cap fits inside the child reserve, shipped and configured" do
    cap = Prima.Authority.depth_cap()
    {configured, _key_max} = Cyfr.Application.execution_slot_caps()

    assert cap <= Slots.child_reserve(Slots.default_max())
    assert cap <= Slots.child_reserve(configured)
  end

  test "the boot warns when one athanor's roots times the depth cap reach the pool" do
    depth = Prima.Authority.depth_cap()

    assert {:warn, message} = Cyfr.Application.execution_slot_footprint(16 * depth, 16)
    assert message =~ "one athanor can hold every slot"
    assert message =~ "16 roots x depth #{depth} = #{16 * depth} >= #{16 * depth} slots"
    assert message =~ "CYFR_CRUCIBLE_MAX_CONCURRENT_PER_TENANT"
    assert message =~ "CYFR_CRUCIBLE_MAX_CONCURRENT"

    assert :ok = Cyfr.Application.execution_slot_footprint(16 * depth + 1, 16)
    assert :ok = Cyfr.Application.execution_slot_footprint(16 * depth, 15)
  end

  # And on the live instance: a root at the athanor's cap is refused with
  # the sentence the operator has always seen, while a child is never
  # refused for it — the other half of the depth guarantee.
  test "a root at the athanor's cap is refused with its sentence, and a child still passes" do
    tenant = "ath_slots_#{System.unique_integer([:positive])}"
    %{key_max: key_max} = Slots.status(@slots)

    holders = for _ <- 1..key_max, do: hold(tenant, :root)

    assert {:error, :key_cap} = Slots.acquire(@slots, tenant, :root, wait_ms: 1_000)
    assert Slots.refusal(:key_cap) == "Athanor at maximum concurrent executions. Retry later."

    assert {:ok, child} = Slots.acquire(@slots, tenant, :child, wait_ms: 1_000)
    Slots.release(@slots, child)

    release(holders)
  end

  test "a child is admitted from the reserve once the foreground is full" do
    %{max: max, key_max: key_max} = Slots.status(@slots)
    per_key = max(1, div(key_max, 2))

    # Roots across athanors, each under its cap, until the foreground is
    # full: the next root is refused at once, and a child is not.
    holders = fill_foreground(max, per_key, [])

    assert {:error, :capacity} = Slots.acquire(@slots, "ath_probe", :root, wait_ms: 0)
    assert Slots.refusal(:capacity) == "Server at maximum concurrent executions. Retry later."

    assert {:ok, child} = Slots.acquire(@slots, "ath_probe", :child, wait_ms: 1_000)
    Slots.release(@slots, child)

    release(holders)
  end

  defp fill_foreground(budget, _per_key, holders) when length(holders) >= budget, do: holders

  defp fill_foreground(budget, per_key, holders) do
    case try_hold("ath_fill_#{div(length(holders), per_key)}", :root) do
      {:ok, pid} -> fill_foreground(budget, per_key, [pid | holders])
      {:error, :capacity} -> holders
    end
  end

  # A process holding one slot of `class` for `key` on the live instance
  # until told to release, linked so a failing test takes it down.
  defp hold(key, class) do
    {:ok, pid} = try_hold(key, class, wait_ms: 5_000)
    pid
  end

  # The same, without waiting: the refusal when there is no slot.
  defp try_hold(key, class, opts \\ [wait_ms: 0]) do
    parent = self()

    pid =
      spawn_link(fn ->
        result = Slots.acquire(@slots, key, class, opts)
        send(parent, {:held, self(), result})

        with {:ok, ref} <- result do
          receive do
            :release -> Slots.release(@slots, ref)
          end
        end
      end)

    assert_receive {:held, ^pid, result}, 5_000

    with {:ok, _ref} <- result, do: {:ok, pid}
  end

  defp release(holders) do
    Enum.each(holders, &send(&1, :release))

    wait_until(
      fn -> Enum.all?(holders, &(not Process.alive?(&1))) end,
      2_000,
      "the holders' release"
    )
  end
end
