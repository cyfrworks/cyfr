# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Catalog do
  @moduledoc """
  The operation catalog as consent sees it.

  A consent shape may only name `tool.action` pairs this server can serve,
  so shape derivation asks the catalog which those are. It asks through
  this port rather than the catalog module directly: the contract is
  written here, in the domain that depends on it, and the one
  implementation (`Cyfr.Ops.Catalog`) answers for every provider it has
  loaded. A provider that cannot load is a boot failure there, never a
  narrower answer here — a digest derived from a partial catalog would
  read as the whole.
  """

  @doc "Every `tool.action` the catalog serves, from its loaded providers."
  @callback tool_actions() :: [String.t()]

  @doc "Whether every configured provider loaded, or which did not."
  @callback providers_loaded() :: :ok | {:error, [module()]}

  @doc "The implementation: `Cyfr.Ops.Catalog`, swappable for a test."
  @spec impl() :: module()
  def impl, do: Application.get_env(:cyfr, :catalog, Cyfr.Ops.Catalog)

  @spec tool_actions() :: [String.t()]
  def tool_actions, do: impl().tool_actions()
end
