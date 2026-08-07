# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Opus.AuthorityDepthSemaphoreTest do
  # async: false — reads live application config.
  use ExUnit.Case, async: false

  # A parent holds its ExecutionSemaphore slot while blocking on a child, so
  # a chain deeper than the per-tenant slot count would self-deadlock the
  # tenant — a denial reachable from one guest. The Authority depth cap must
  # therefore sit strictly below both the shipped default and whatever this
  # deployment actually configures. If this test is red, the configuration
  # is unsafe (or the cap grew); do not weaken the assertion.
  test "authority depth cap sits strictly below the per-tenant execution slots" do
    cap = Sanctum.Authority.depth_cap()

    assert cap < Opus.ExecutionSemaphore.default_tenant_slots()

    configured =
      Application.get_env(
        :cyfr,
        :max_concurrent_executions_per_tenant,
        Opus.ExecutionSemaphore.default_tenant_slots()
      )

    assert cap < configured
  end
end
