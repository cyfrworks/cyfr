# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.SSE.Registry do
  @moduledoc """
  The stream slots `CyfrWeb.SSE.claim_slot/3` counts: duplicate keys, one
  entry per open stream. A stream that ends releases its entry
  (`CyfrWeb.SSE.release_slot/2`), and an entry dies with the process that
  registered it, so a vanished client frees its slot without bookkeeping.
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

  @doc "Release every stream the calling process holds under `key`."
  @spec unregister(term()) :: :ok
  def unregister(key), do: Registry.unregister(__MODULE__, key)
end
