# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.VaultRef do
  @moduledoc """
  Constructs and classifies `vault:<name>` credential references.
  """

  @prefix "vault:"

  @doc "The reference prefix."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "Build the reference for a vault entry name (or id)."
  @spec build(String.t()) :: String.t()
  def build(name) when is_binary(name), do: @prefix <> name

  @doc "The entry name a reference carries."
  @spec parse(term()) :: {:ok, String.t()} | :error
  def parse(@prefix <> name) when name != "", do: {:ok, name}
  def parse(_), do: :error

  @doc "Whether a header value is a vault reference."
  @spec vault_ref?(term()) :: boolean()
  def vault_ref?(value), do: is_binary(value) and String.starts_with?(value, @prefix)
end
