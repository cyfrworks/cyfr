# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.EngineTest do
  @moduledoc """
  The runtime's own authority check, in the VM that runs a component: a
  run given no authority, or anything but one, raises before anything
  compiles, whatever else its options say, and one given an authority,
  the node's limits and its attempt's host client goes on to compile. A
  run missing the limits or the host client raises before anything
  compiles too. That a dispatched run's runner is handed the authority it
  was dispatched with is `Locus.Runtime.AuthorityPlumbingTest`'s, in CYFR's
  suite.
  """

  use ExUnit.Case, async: true

  alias Locus.Runtime.Test.ScriptedHost

  defp client, do: ScriptedHost.attempt!(ScriptedHost.start!()).client

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
        authority: Prima.Authority.zero(),
        limits: Prima.Authority.zero_limits(),
        host: client()
      )

    assert {:error, "Component compilation failed: " <> _} = result
  end

  test "the runtime refuses a run whose authority is not an authority" do
    assert_raise ArgumentError, ~r/an opts filter dropped it/, fn ->
      Locus.Runtime.Engine.execute_component(<<0, 1, 2, 3>>, %{}, authority: false)
    end
  end

  test "the runtime refuses a run without the node's limits or its attempt's host client" do
    authority = Prima.Authority.zero()

    assert_raise KeyError, ~r/:limits/, fn ->
      Locus.Runtime.Engine.execute_component(<<0, 1, 2, 3>>, %{},
        authority: authority,
        host: client()
      )
    end

    assert_raise KeyError, ~r/:host/, fn ->
      Locus.Runtime.Engine.execute_component(<<0, 1, 2, 3>>, %{},
        authority: authority,
        limits: Prima.Authority.zero_limits()
      )
    end
  end
end
