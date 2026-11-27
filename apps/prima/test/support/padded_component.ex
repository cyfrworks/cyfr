# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Test.PaddedComponent do
  @moduledoc """
  A component grown to an exact size: its bytes and one custom section
  after its last, a section the component model admits anywhere and gives
  no meaning, so the padded component validates and runs as the one it
  pads.
  """

  import Bitwise

  # Section id 0 is a custom section; its content is a name, then bytes.
  @custom 0
  @name "pad"

  @doc "`component` padded to `size` bytes, at least 8 more than it has."
  @spec pad(binary(), pos_integer()) :: binary()
  def pad(component, size) when is_binary(component) and size >= byte_size(component) + 8 do
    extra = size - byte_size(component)
    name = leb(byte_size(@name)) <> @name

    content =
      Enum.find_value(1..5, fn width ->
        content = extra - 1 - width
        if byte_size(leb(content)) == width, do: content
      end)

    padding = :binary.copy(<<0>>, content - byte_size(name))
    padded = component <> <<@custom>> <> leb(content) <> name <> padding
    ^size = byte_size(padded)
    padded
  end

  defp leb(value) when value < 0x80, do: <<value>>
  defp leb(value), do: <<0x80 ||| (value &&& 0x7F)>> <> leb(value >>> 7)
end
