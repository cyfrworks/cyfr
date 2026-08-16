# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Opus.AuthorityDepthSemaphoreTest do
  # async: false — reads live application config.
  use ExUnit.Case, async: false

  # A parent holds its ExecutionSemaphore slot while blocking on a child, so
  # a chain deeper than the slots a child can always reach would self-
  # deadlock — a denial reachable from one guest. Children take the child
  # reserve (never the athanor's cap), so the Authority depth cap must sit
  # within that reserve, for the shipped default and for whatever this
  # deployment configures. If this test is red, the configuration is unsafe
  # (or the cap grew); do not weaken the assertion.
  test "authority depth cap fits inside the child reserve" do
    cap = Sanctum.Authority.depth_cap()

    assert cap <= Opus.ExecutionSemaphore.child_reserve(Opus.ExecutionSemaphore.default_slots())

    configured =
      Application.get_env(
        :cyfr,
        :max_concurrent_executions,
        Opus.ExecutionSemaphore.default_slots()
      )

    assert cap <= Opus.ExecutionSemaphore.child_reserve(configured)
  end

  # And a child acquisition is never refused for the athanor's root cap —
  # the other half of the same guarantee, on the live semaphore.
  test "a child acquire never sees :tenant_limit" do
    Opus.ExecutionSemaphore.force_release_all()
    tenant = "ath_depth_#{System.unique_integer([:positive])}"

    holders =
      for _ <- 1..Opus.ExecutionSemaphore.default_tenant_slots() do
        parent = self()

        pid =
          spawn(fn ->
            :ok = Opus.ExecutionSemaphore.acquire(5_000, :root, tenant)
            send(parent, {:held, self()})

            receive do
              :release -> Opus.ExecutionSemaphore.release()
            end
          end)

        assert_receive {:held, ^pid}, 2_000
        pid
      end

    assert {:error, :tenant_limit} = Opus.ExecutionSemaphore.acquire(1_000, :root, tenant)
    assert :ok = Opus.ExecutionSemaphore.acquire(1_000, :child, tenant)
    Opus.ExecutionSemaphore.release()

    Enum.each(holders, &send(&1, :release))
  end
end
