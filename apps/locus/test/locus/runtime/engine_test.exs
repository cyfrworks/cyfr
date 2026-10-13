# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.EngineTest do
  @moduledoc """
  The runtime's own authority check, in the VM that runs a component: a
  run given no authority raises before anything compiles, whatever else
  its options say, and one given an authority goes on to compile. That a
  dispatched run's runner is handed the authority it was dispatched with
  is `Locus.Runtime.AuthorityPlumbingTest`'s, in CYFR's suite.
  """

  use ExUnit.Case, async: true

  test "the runtime itself refuses a run without an authority" do
    assert_raise ArgumentError, ~r/an opts filter dropped it/, fn ->
      Locus.Runtime.Engine.execute_component(<<0, 1, 2, 3>>, %{})
    end
  end

  test "the runtime accepts a run whose authority is present" do
    # Garbage bytes fail at compile, not at the authority check — proving the
    # check passed and execution was attempted.
    result =
      Locus.Runtime.Engine.execute_component(<<0, 1, 2, 3>>, %{},
        authority: Prima.Authority.zero()
      )

    assert {:error, _} = result
  end

  test "no option lets a run without an authority through" do
    # `authority_required: false` once opted a run out of the check; the
    # option no longer exists, and passing it changes nothing.
    assert_raise ArgumentError, ~r/an opts filter dropped it/, fn ->
      Locus.Runtime.Engine.execute_component(<<0, 1, 2, 3>>, %{}, authority_required: false)
    end
  end
end
