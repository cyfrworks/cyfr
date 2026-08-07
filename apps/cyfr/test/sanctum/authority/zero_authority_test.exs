# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.ZeroAuthorityTest do
  use ExUnit.Case, async: true

  alias Sanctum.Authority
  alias Sanctum.Limits
  alias Sanctum.Policy

  # §6 "ZeroAuthority" gate: no resources, no control plane, and the exact
  # model §3.5 constants — asserted as literals on BOTH sides, never derived.

  test "zero/0 carries nothing" do
    zero = Authority.zero()

    assert zero.profile_id == nil
    assert zero.consent_id == nil
    assert zero.source_ref == nil
    assert zero.profile_kind == nil
    assert zero.policy == :none
    assert zero.activation == %{}
    assert zero.invoke_mode == :open_inert
    assert zero.cursor == :unbound
    assert zero.resources == :none
    assert zero.chain == []
    assert zero.depth == 0
    refute Authority.bound?(zero)
    assert Authority.current_node(zero) == :unbound
  end

  test "zero_limits/0 are exactly the model §3.5 literals" do
    expected = %Limits{
      timeout: "30s",
      max_memory_bytes: 67_108_864,
      max_request_size: 1_048_576,
      max_response_size: 5_242_880,
      rate_limit: %{requests: 100, window: "1m"},
      max_concurrent_tasks: 1,
      batch_timeout: "30s"
    }

    assert Authority.zero_limits() == expected
    assert Authority.limits(Authority.zero()) == expected
  end

  test "zero limits are strictly tighter than Policy defaults on three fields" do
    # Guards against anyone "simplifying" the literals into a derivation:
    # Policy.default/0 is looser on exactly these, so a derivation would
    # silently widen what unconsented code gets.
    zero = Authority.zero_limits()
    default = Policy.default()

    assert zero.timeout == "30s" and default.timeout == "1m"
    assert zero.batch_timeout == "30s" and default.batch_timeout == "5m"
    assert zero.max_concurrent_tasks == 1 and default.max_concurrent_tasks == 10
  end

  test "zero budget admits exactly one spawn" do
    zero = Authority.zero()

    assert Authority.budget(zero) == %{in_flight: 0, cap: 1}
    assert Authority.try_acquire_invoke(zero) == :ok
    assert Authority.try_acquire_invoke(zero) == {:error, :invoke_budget_exhausted}
    assert Authority.release_invoke(zero) == :ok
    assert Authority.try_acquire_invoke(zero) == :ok
  end

  test "every zero/0 call is an independent budget" do
    a = Authority.zero()
    b = Authority.zero()

    assert Authority.try_acquire_invoke(a) == :ok
    assert Authority.try_acquire_invoke(b) == :ok
  end
end
