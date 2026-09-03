# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Text do
  @moduledoc "Byte-bounded text: what has to fit a cap and still be valid UTF-8."

  @doc """
  `text` cut to at most `max` bytes on a character boundary, with `marker`
  appended when anything was cut. The marker's bytes are the caller's to
  budget for; the cut itself never splits a character.
  """
  @spec cut(String.t(), pos_integer(), String.t()) :: String.t()
  def cut(text, max, marker \\ "…") when is_binary(text) and is_integer(max) and max >= 0 do
    if byte_size(text) <= max, do: text, else: whole(binary_part(text, 0, max)) <> marker
  end

  defp whole(bin) do
    if String.valid?(bin), do: bin, else: whole(binary_part(bin, 0, byte_size(bin) - 1))
  end
end
