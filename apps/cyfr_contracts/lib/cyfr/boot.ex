# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Boot do
  @moduledoc """
  Identifies this application boot. Execution attempts and control-plane
  claims carry this id; each restart receives a different id.

  Host mints the id at the top of its application `start/2`, before its
  children run. This shared runtime primitive holds the identity in a
  persistent term so lower applications can read it without calling Host.
  An uninitialized reader raises; standalone callers initialize explicitly.
  """

  defmodule NotInitializedError do
    defexception message: "boot identity has not been initialized"
  end

  @key {__MODULE__, :id}

  @doc "This boot's id."
  @spec id() :: String.t()
  def id do
    case :persistent_term.get(@key, nil) do
      nil -> raise NotInitializedError
      id -> id
    end
  end

  @doc false
  # Only the owning application start replaces the identity of a live boot.
  def mint do
    id = "#{node()}#" <> Cyfr.UUID7.generate_id("boot")
    :persistent_term.put(@key, id)
    id
  end
end
