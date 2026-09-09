# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.GlobalPages do
  @moduledoc """
  The console pages that have no estate in their address.

  Every other page lives under `/a/<athanor>` — the workbench, focused on
  one estate. A global page spans every estate the person belongs to; the
  chat is one. The engine needs the list too (a navigate intent to a global
  page is pushed as it is, never prefixed with the focus), and the engine
  must not name the console, so the list is glue: `PrismWeb.Nav` derives
  its links from it, `Aqua.Intents` its allowlist.
  """

  @paths ~w(/chat)

  @doc "The global pages' paths."
  @spec paths() :: [String.t()]
  def paths, do: @paths

  @doc "Whether `path` (query string allowed) is a global page's."
  @spec global?(String.t()) :: boolean()
  def global?(path) when is_binary(path) do
    base = path |> String.split("?", parts: 2) |> hd()
    base in @paths
  end

  def global?(_), do: false
end
