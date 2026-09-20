# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Boot do
  @moduledoc """
  Identifies this application boot. Execution attempts and control-plane
  claims carry this id; each restart receives a different id.

  The id is minted by the application that starts, at the top of its
  `start/2`; this module only holds it. A boot that never minted one
  still answers, lazily, so a bare script or an early caller reads an id
  rather than `nil`.
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
