# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Version do
  @moduledoc """
  This build's version, embedded when the module compiles.

  The value is the contracts application's own `mix.exs` version, read at
  compile time, so a release answers it without its application being
  loaded and a checkout of the contracts alone compiles it. Every
  application's `mix.exs` and the bridge's package move together
  (`scripts/release.sh`); `Prima.VersionTest` holds them to this value.
  """

  @version Mix.Project.config()[:version]

  @doc "This build's version, e.g. `\"0.6.0\"`."
  @spec current() :: String.t()
  def current, do: @version
end
