# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.RuntimeTest do
  @moduledoc """
  The runtime's own check of `authority_required`, in the VM that runs a
  component: a run that requires an authority and was given none raises
  before anything compiles, and one given an authority goes on to compile.
  That a dispatched run's runner is handed the authority it was
  dispatched with is `Opus.AuthorityPlumbingTest`'s, in CYFR's suite.
  """

  use ExUnit.Case, async: true

  test "the runtime itself re-checks authority_required" do
    assert_raise ArgumentError, ~r/an opts filter dropped it/, fn ->
      Opus.Runtime.execute_component(<<0, 1, 2, 3>>, %{}, authority_required: true)
    end
  end

  test "the runtime accepts authority_required when the authority is present" do
    # Garbage bytes fail at compile, not at the authority check — proving the
    # check passed and execution was attempted.
    result =
      Opus.Runtime.execute_component(<<0, 1, 2, 3>>, %{},
        authority: Prima.Authority.zero(),
        authority_required: true
      )

    assert {:error, _} = result
  end
end
