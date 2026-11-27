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
  @name <<3, "pad">>

  # The section's length is written in the five bytes a u32's LEB128 may
  # take, whatever its value, so every size has one padding: the id, the
  # length and the name are 10 bytes.
  @least 1 + 5 + byte_size(@name)

  @doc "`component` padded to `size` bytes, at least #{@least} more than it has."
  @spec pad(binary(), pos_integer()) :: binary()
  def pad(component, size) when is_binary(component) and is_integer(size) do
    extra = size - byte_size(component)

    if extra < @least,
      do:
        raise(
          ArgumentError,
          "a component of #{byte_size(component)} bytes pads to #{byte_size(component) + @least} " <>
            "bytes or more, not #{size}"
        )

    content = extra - 1 - 5
    padding = :binary.copy(<<0>>, content - byte_size(@name))
    component <> <<@custom>> <> leb5(content) <> @name <> padding
  end

  defp leb5(value) when value < 1 <<< 32 do
    <<0x80 ||| (value &&& 0x7F), 0x80 ||| (value >>> 7 &&& 0x7F),
      0x80 ||| (value >>> 14 &&& 0x7F), 0x80 ||| (value >>> 21 &&& 0x7F), value >>> 28>>
  end
end
