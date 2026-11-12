# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.TestSeam do
  @moduledoc """
  The one gate for test-only switches: a hook a suite sets and no release
  reads.

  `value/2` answers what its `read` answers in a build compiled with the
  test permission, `config :prima, test_seams_permitted: true`, which the
  test configurations alone set (`config/test.exs`, and the island builds'
  own configurations under test); every other build answers `default` and
  never calls `read`, so a release reads no seam's key at all, whatever its
  start-up configuration (`sys.config`, `ERL_AFLAGS`) says.

  `value/2` is a macro: the permission is compiled into each module that
  calls it, so every application that uses the gate records the key in its
  own compile-time environment, and a release refuses to boot when the
  value it is handed differs from the one it was compiled with. A caller
  `require`s this module. `value/3` is the decision itself, pure.
  """

  @doc """
  `read.()` in a build compiled with the test permission, else `default`
  with `read` never called.
  """
  defmacro value(default, read) do
    permitted = Application.compile_env(__CALLER__, :prima, :test_seams_permitted, false)

    quote do
      Prima.TestSeam.value(unquote(permitted), unquote(default), unquote(read))
    end
  end

  @doc """
  The decision: `read.()` when `permitted`, else `default` with `read`
  never called.
  """
  @spec value(boolean(), value, (-> value)) :: value when value: term()
  def value(true, _default, read) when is_function(read, 0), do: read.()
  def value(false, default, read) when is_function(read, 0), do: default
end
