# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Digest do
  @moduledoc """
  The one content-digest implementation and the one spelling of its result.

  Every producer (registration validation, OCI blob upload/pull, the
  executor's integrity gate) uses this, so a digest computed anywhere
  compares byte-equal to a digest computed anywhere else — the integrity
  gate never has to guess which format a row carries.
  """

  @doc """
  SHA-256 of the bytes, formatted `sha256:<lowercase hex>`.
  """
  @spec sha256(binary()) :: String.t()
  def sha256(bytes) when is_binary(bytes) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  end
end
