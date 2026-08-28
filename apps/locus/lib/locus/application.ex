# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Application do
  @moduledoc """
  Locus's own supervision tree: the build-slot limiter and the task pool
  builds run on.

  A component build is `cargo component build` or npm+Vite — minutes, not
  milliseconds — so builds get their own pool rather than riding the MCP
  request pool. These children used to be grafted onto cyfr's tree behind
  a `Code.ensure_loaded?` guard; the app that owns the processes now
  supervises them.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Locus.BuildLimiter,
      {Task.Supervisor, name: Locus.TaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Locus.Supervisor)
  end
end
