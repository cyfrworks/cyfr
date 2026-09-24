# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Hex do
  @moduledoc """
  Short random hex identifiers — progress ids, scratch dirs, build labels.

  Generates unordered 64-bit labels for ephemeral resources.
  Use `Prima.UUID7` for time-ordered row identifiers.
  """

  @doc "A 16-character lowercase hex label from 64 CSPRNG bits."
  @spec short() :: String.t()
  def short, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
