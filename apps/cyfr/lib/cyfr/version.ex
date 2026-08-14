# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Version do
  @moduledoc """
  This build's version, read from the loaded application.

  One reader, because the alternative was four. Modules used to carry
  `Mix.Project.config()[:version] || "0.1.0"`, which is resolved at compile
  time and falls back to a number no release has ever had — the same bug
  `Emissary.MCP.Protocol` documents having already fixed once, announcing
  0.1.0 from a 0.5.8 build. `:application.get_key/2` reads what is actually
  running.
  """

  @doc """
  The running version, e.g. `"0.6.0"`.

  Returns `"unknown"` only before the application is loaded, which in
  practice means tooling rather than a served request.
  """
  @spec current() :: String.t()
  def current do
    case :application.get_key(:cyfr, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      :undefined -> "unknown"
    end
  end
end
