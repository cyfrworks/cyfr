# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Boot do
  @moduledoc """
  This boot's name: one id minted when the application starts, carried by
  every row this process opens (execution attempts, the control-plane
  claim). Never `node()` — distribution is not configured, so every node
  was `nonode@nohost` and nothing could tell its own lapsed lease from
  another node's crash. A restart is a different boot, which is exactly
  what a lease sweeper needs to know.
  """

  @key {__MODULE__, :id}

  @doc "This boot's id."
  @spec id() :: String.t()
  def id do
    case :persistent_term.get(@key, nil) do
      nil -> mint()
      id -> id
    end
  end

  @doc false
  # Minted once at application start; the lazy path in `id/0` covers only a
  # caller that beat the start.
  def mint do
    id = "#{node()}#" <> Cyfr.UUID7.generate_id("boot")
    :persistent_term.put(@key, id)
    id
  end
end
