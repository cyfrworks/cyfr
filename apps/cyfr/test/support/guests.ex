# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.Guests do
  @moduledoc """
  The suite's guests (`test_wasm/guests/`): a component of each executable
  world, the reagent's, the catalyst's and the formula's, each answering
  `{"ran":true}` to any input but `{"trap":true}`, on which it traps. A
  test that registers a component publishes the guest of the type it
  declares, since registration holds a component to its declared type's
  world (`Prima.Wasm.validate/2`).
  """

  @types ~w(reagent catalyst formula)
  @dir Path.expand("test_wasm/guests", __DIR__)

  for type <- @types, do: @external_resource(Path.join(@dir, "#{type}.wasm"))

  @wasm Map.new(@types, &{&1, File.read!(Path.join(@dir, "#{&1}.wasm"))})

  @doc "The guest of the executable type `type`, its bytes."
  @spec wasm(atom() | String.t()) :: binary()
  def wasm(type) when is_atom(type), do: wasm(Atom.to_string(type))
  def wasm(type) when type in @types, do: Map.fetch!(@wasm, type)
end
