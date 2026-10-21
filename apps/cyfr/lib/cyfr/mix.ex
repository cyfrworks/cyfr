# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Mix do
  @moduledoc """
  The boundary of the Mix tasks under `lib/mix/tasks` that render from the
  gate's operation table or a shared contract, naming exactly the
  boundaries listed here. The tasks that render from the host's own
  rosters (`mix cyfr.gen.configuration_guide`, `mix cyfr.gen.guard_table`)
  classify to `Cyfr`.
  """

  use Boundary, top_level?: true, deps: [Sanctum], exports: [], check: [aliases: true]

  @doc """
  Formats a generated Go file in place with the Go toolchain's `gofmt`,
  which reads none of the server's settings and is given none of them.
  Without a toolchain the file stays as rendered, and `gofmt` runs where
  the CLI is built.
  """
  @spec gofmt(Path.t()) :: :ok
  def gofmt(path) do
    case System.find_executable("gofmt") do
      nil ->
        :ok

      gofmt ->
        unset =
          for {name, _} <- System.get_env(), String.starts_with?(name, "CYFR_"), do: {name, nil}

        {_, 0} = System.cmd(gofmt, ["-w", path], env: unset)
        :ok
    end
  end
end
