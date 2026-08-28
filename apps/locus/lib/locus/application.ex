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
    children =
      [
        Locus.BuildLimiter,
        {Task.Supervisor, name: Locus.TaskSupervisor}
      ] ++ builder_endpoint()

    Supervisor.start_link(children, strategy: :one_for_one, name: Locus.Supervisor)
  end

  # The builder container's HTTP face — only when this node IS the builder
  # (the `builder` release sets CYFR_BUILDER_LISTEN=true). The app image
  # never listens on this port.
  defp builder_endpoint do
    if Application.get_env(:cyfr, :builder_listen, false) do
      port = Application.get_env(:cyfr, :builder_port, 4100)
      [{Bandit, plug: Locus.BuilderService, port: port, ip: {0, 0, 0, 0}}]
    else
      []
    end
  end
end
