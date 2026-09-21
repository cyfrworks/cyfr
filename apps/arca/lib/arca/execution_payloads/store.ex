# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExecutionPayloads.Store do
  @moduledoc """
  The byte store behind execution payloads. An object is named by its
  segments under the athanor's reserved `payloads/` root, written once,
  read back whole and deleted by name; `Arca.ExecutionPayloads` verifies
  what comes back against the row's digest and never asks a store to
  overwrite.

  `config :arca, :execution_payload_store` names the module. The shipped
  store is `Arca.ExecutionPayloads.Store.Overlay`, which writes the
  athanor's own tree under the overlay's internal-write scope.
  """

  @callback put(Cyfr.Actor.t(), [String.t()], binary()) :: :ok | {:error, term()}
  @callback get(Cyfr.Actor.t(), [String.t()]) :: {:ok, binary()} | {:error, :not_found | term()}
  @callback delete(Cyfr.Actor.t(), [String.t()]) :: :ok | {:error, :not_found | term()}

  @doc "The configured store module."
  @spec impl() :: module()
  def impl,
    do: Application.get_env(:arca, :execution_payload_store, Arca.ExecutionPayloads.Store.Overlay)
end
