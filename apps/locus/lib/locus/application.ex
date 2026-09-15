# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Application do
  @moduledoc """
  Locus's own supervision tree: the build-slot limiter, the task pool the
  build tool's background work runs on, the client of cyfr-spawn when this
  node was started by it, and the builder service when this node is the
  builder.
  """

  use Application

  @impl true
  def start(_type, _args) do
    spawner? = Locus.Spawner.channel_inherited?()
    listen? = Application.get_env(:cyfr, :builder_listen, false)

    children =
      [
        Locus.BuildLimiter,
        {Task.Supervisor, name: Locus.TaskSupervisor}
      ] ++ spawner(spawner?) ++ builder_endpoint(listen?, spawner?)

    Supervisor.start_link(children, strategy: :one_for_one, name: Locus.Supervisor)
  end

  defp spawner(true), do: [Locus.Spawner]
  defp spawner(false), do: []

  @doc """
  The builder container's HTTP face, when this node is the builder (the
  `builder` release sets CYFR_BUILDER_LISTEN=true). The builder serves
  builds only through cyfr-spawn, which runs each under a uid of its own;
  without the spawner's channel the boot is refused. In compose the
  container sits on the builder network alone, so every interface is that
  network; elsewhere `CYFR_BUILDER_BIND` names the one address to listen on.
  """
  @spec builder_endpoint(boolean(), boolean()) :: [
          Supervisor.child_spec() | {module(), keyword()}
        ]
  def builder_endpoint(false = _listen?, _spawner?), do: []

  def builder_endpoint(true, false) do
    raise "[Locus] FATAL: the builder runs builds only through cyfr-spawn, which starts it with " <>
            "its channel on fd 3 (CYFR_SPAWN_CHANNEL); fd 3 is not that channel. Start the builder " <>
            "through `cyfr-spawn serve --pool build:… -- /app/bin/builder start` (the image's entrypoint)."
  end

  def builder_endpoint(true, true) do
    port = Application.get_env(:cyfr, :builder_port, 4100)
    ip = bind_address!(Application.get_env(:cyfr, :builder_bind, "0.0.0.0"))
    [{Bandit, plug: Locus.BuilderService, port: port, ip: ip}]
  end

  @doc """
  The IP address the builder listens on, from its dotted or colon
  spelling; an address that does not parse refuses the boot rather than
  listening somewhere else.
  """
  @spec bind_address!(String.t()) :: :inet.ip_address()
  def bind_address!(text) when is_binary(text) do
    case :inet.parse_address(String.to_charlist(text)) do
      {:ok, address} ->
        address

      {:error, _} ->
        raise "CYFR_BUILDER_BIND=#{inspect(text)} is not an IP address; the builder refuses to boot"
    end
  end
end
