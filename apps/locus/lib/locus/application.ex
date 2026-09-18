# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Application do
  @moduledoc """
  Locus's own supervision tree: the build slots, the task pool the build
  tool's background work runs on, the client of cyfr-spawn when this node
  was started by it, and the builder service when this node is the builder.
  """

  use Application

  # A `cargo component build` or npm bundle occupies a CPU core and hundreds
  # of MB for minutes, so a node accepts a couple at once, and one per
  # athanor: the total is small, and a single athanor must not be able to
  # hold every slot.
  @default_max_builds 2
  @default_max_builds_per_tenant 1

  @impl true
  def start(_type, _args) do
    spawner? = Locus.Spawner.channel_inherited?()
    listen? = Application.get_env(:cyfr, :builder_listen, false)

    children =
      [
        build_slots(),
        {Task.Supervisor, name: Locus.TaskSupervisor}
      ] ++ spawner(spawner?) ++ builder_endpoint(listen?, spawner?)

    Supervisor.start_link(children, strategy: :one_for_one, name: Locus.Supervisor)
  end

  defp spawner(true), do: [Locus.Spawner]
  defp spawner(false), do: []

  @doc """
  The build slots, `Locus.BuildSlots`: one `Cyfr.Slots` instance whose caps
  are read once at boot, `CYFR_MAX_CONCURRENT_BUILDS` (`:cyfr,
  :max_concurrent_builds`) in all and `CYFR_MAX_CONCURRENT_BUILDS_PER_TENANT`
  per athanor. A build past either cap is refused, never queued: a backlog
  of multi-minute builds behind a synchronous tool call helps nobody. A
  build holds its slot in the process that runs it, so a holder the tool
  layer brutal-kills on its deadline, or an SSE disconnect exits, gives the
  slot back by its monitor.
  """
  @spec build_slots() :: {Cyfr.Slots, [Cyfr.Slots.option()]}
  def build_slots do
    {Cyfr.Slots,
     name: Locus.BuildSlots,
     max: configured_max_builds(),
     key_max:
       Application.get_env(
         :cyfr,
         :max_concurrent_builds_per_tenant,
         @default_max_builds_per_tenant
       ),
     child_reserve: 0,
     policy: :reject}
  end

  @doc """
  The cap a build refusal names: the running instance's, or the configured
  one while the instance is down, so the refusal reads the same either way.
  """
  @spec max_builds() :: pos_integer()
  def max_builds do
    case Cyfr.Slots.status(Locus.BuildSlots) do
      %{error: :unavailable} -> configured_max_builds()
      %{max: max} -> max
    end
  end

  defp configured_max_builds,
    do: Application.get_env(:cyfr, :max_concurrent_builds, @default_max_builds)

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
