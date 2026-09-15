# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.ZeroAuthorityTest do
  use ExUnit.Case, async: true

  alias Cyfr.Authority

  # A zero authority's invoke budget admits one spawn at a time, per zero/0 call.

  test "zero budget admits exactly one spawn" do
    zero = Authority.zero()

    assert Sanctum.Authority.budget(zero) == %{in_flight: 0, cap: 1}
    assert Sanctum.Authority.try_acquire_invoke(zero) == :ok
    assert Sanctum.Authority.try_acquire_invoke(zero) == {:error, :invoke_budget_exhausted}
    assert Sanctum.Authority.release_invoke(zero) == :ok
    assert Sanctum.Authority.try_acquire_invoke(zero) == :ok
  end

  test "every zero/0 call is an independent budget" do
    a = Authority.zero()
    b = Authority.zero()

    assert Sanctum.Authority.try_acquire_invoke(a) == :ok
    assert Sanctum.Authority.try_acquire_invoke(b) == :ok
  end
end
