# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Bytes do
  @moduledoc """
  How a count of bytes is written where a person reads it, the pages and a
  refusal's sentence alike: one decimal of the largest unit it reaches,
  "1.5 GB", "384.0 MB", "2.0 KB", and whole bytes below that, "512 B". The
  units are of 1024.
  """

  @kib 1024
  @mib 1024 * @kib
  @gib 1024 * @mib

  @doc "`bytes` as a person reads it."
  @spec format(integer()) :: String.t()
  def format(bytes) when is_integer(bytes) and bytes >= @gib,
    do: "#{one_place(bytes / @gib)} GB"

  def format(bytes) when is_integer(bytes) and bytes >= @mib,
    do: "#{one_place(bytes / @mib)} MB"

  def format(bytes) when is_integer(bytes) and bytes >= @kib,
    do: "#{one_place(bytes / @kib)} KB"

  def format(bytes) when is_integer(bytes), do: "#{bytes} B"

  # One decimal place, never an exponent: "1000.0 MB", not "1.0e3 MB".
  defp one_place(value), do: :erlang.float_to_binary(value, decimals: 1)
end
