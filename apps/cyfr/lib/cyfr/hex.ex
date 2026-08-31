# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Hex do
  @moduledoc """
  Short random hex identifiers — progress ids, scratch dirs, build labels.

  Not row ids: those are `Cyfr.UUID7` (time-ordered, prefixed, pinned by
  `Cyfr.IdMintingSeamTest`). This is the other mint — an unordered 64-bit
  collision-resistant label for ephemeral things — which was spelled
  `:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)` inline in
  five modules across three apps.
  """

  @doc "A 16-character lowercase hex label from 64 CSPRNG bits."
  @spec short() :: String.t()
  def short, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
