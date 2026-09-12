# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Application do
  @moduledoc """
  Locus's own supervision tree: the build-slot limiter and the task pool
  builds run on.

  Supervises dedicated build workers for cargo-component and npm/Vite jobs.
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
  # never listens on this port. In compose the container sits on the
  # builder network alone, so every interface is that network; elsewhere
  # `CYFR_BUILDER_BIND` names the one address to listen on.
  defp builder_endpoint do
    if Application.get_env(:cyfr, :builder_listen, false) do
      port = Application.get_env(:cyfr, :builder_port, 4100)
      ip = bind_address!(Application.get_env(:cyfr, :builder_bind, "0.0.0.0"))
      [{Bandit, plug: Locus.BuilderService, port: port, ip: ip}]
    else
      []
    end
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
