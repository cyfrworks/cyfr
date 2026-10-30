# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Crockford do
  @moduledoc """
  Crockford base32, the alphabet a person reads back to a screen:
  `0123456789ABCDEFGHJKMNPQRSTVWXYZ`, five bits a symbol, most significant
  bits first. It is spelled here once, for `Prima.RecoveryCode` and for
  `Prima.PersonAssertion.comparison_code/1`.

  `encode/1` takes a bitstring whose size is a multiple of five.
  `decode/1` reads the uppercase alphabet and, as Crockford base32 does,
  `O` as `0` and `I` and `L` as `1`; it maps no case and ignores no
  separator, which each reader does for itself before it decodes.
  """

  @alphabet "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

  @index @alphabet
         |> String.to_charlist()
         |> Enum.with_index()
         |> Map.new()
         |> Map.merge(%{?O => 0, ?I => 1, ?L => 1})

  @doc "The 32 symbols, in value order."
  @spec alphabet() :: String.t()
  def alphabet, do: @alphabet

  @doc "The symbols of `bits`, one per five bits, most significant first."
  @spec encode(bitstring()) :: String.t()
  def encode(bits) when is_bitstring(bits) and rem(bit_size(bits), 5) == 0 do
    for <<value::5 <- bits>>, into: "", do: <<:binary.at(@alphabet, value)>>
  end

  @doc """
  The bits `text` spells, five per symbol, or `:error` at the first
  character that is no symbol of the alphabet nor `O`, `I` or `L`.
  """
  @spec decode(binary()) :: {:ok, bitstring()} | :error
  def decode(text) when is_binary(text), do: decode(text, <<>>)

  defp decode(<<>>, bits), do: {:ok, bits}

  defp decode(<<char, rest::binary>>, bits) do
    case Map.fetch(@index, char) do
      {:ok, value} -> decode(rest, <<bits::bitstring, value::5>>)
      :error -> :error
    end
  end
end
