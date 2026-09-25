# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.SSE.Registry do
  @moduledoc """
  The stream slots `CyfrWeb.SSE.claim_slot/3` counts: duplicate keys, one
  entry per open stream. An entry dies with the process that registered it,
  so a vanished client frees its slot without bookkeeping.
  """

  @doc "The registry's child spec, under this module's name."
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg), do: Registry.child_spec(keys: :duplicate, name: __MODULE__)

  @doc "How many streams are open under `key`."
  @spec count(term()) :: non_neg_integer()
  def count(key), do: length(Registry.lookup(__MODULE__, key))

  @doc "Register the calling process as one open stream under `key`."
  @spec register(term(), term()) :: {:ok, pid()} | {:error, {:already_registered, pid()}}
  def register(key, value), do: Registry.register(__MODULE__, key, value)
end
