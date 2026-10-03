# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Application do
  @moduledoc """
  A Locus node's supervision tree, in dependency order: the build slots,
  the client of cyfr-keeper when this node was started by it, the builds
  service's listener when this node serves builds, and the backends
  service's children (`Locus.Backends.children/0`) when it serves backends.

  A node serves either service, both or none by which keys it holds: builds
  with a builds key (`Locus.Config.request_key/0`), backends with a
  backends key (`Locus.Config.backends_key/0`). The `locus` release holds
  at least one, since its boot refuses without either
  (`config/locus_runtime.exs`), and a node whose environment was never read
  serves none. A node that serves runs every build and every backend
  through cyfr-keeper, each under a uid and a memory bound of its own, so
  serving without the keeper's channel refuses the boot. The one node that
  serves without it is the test build's, through the direct launcher its
  test support compiles (`Locus.Executor.direct_launcher/0`), which no
  other build compiles: no setting of a release reaches it.

  The tree restarts `:rest_for_one`. Both services depend on the keeper's
  client: when cyfr-keeper's channel is lost the client stops, everything
  started after it stops with it, and a client that cannot come back ends
  the application, and with it the release.
  """

  use Application

  @impl true
  def start(_type, _args) do
    builds? = Locus.Config.request_key() != nil
    backends? = Locus.Config.backends_key() != nil
    keeper? = Locus.Keeper.channel_inherited?()

    if builds? or backends?, do: configure_logging()

    # The nonces each service has seen, owned by the application so a
    # listener restart forgets none within the header window.
    :ok = Locus.BuilderService.init_nonces()
    :ok = Locus.Backends.init_nonces()

    Supervisor.start_link(children(%{builds: builds?, backends: backends?}, keeper?),
      strategy: :rest_for_one,
      name: Locus.Supervisor
    )
  end

  @typedoc "Which services a node serves."
  @type services :: %{builds: boolean(), backends: boolean()}

  @doc """
  The children of `Locus.Supervisor` for a node that serves `services`,
  started by cyfr-keeper or not, under the direct launcher this build has
  (`Locus.Executor.direct_launcher/0`, `nil` in every build but the test
  one's). Serving either service without the keeper and without a direct
  launcher raises: the boot is refused.
  """
  @spec children(services(), boolean(), module() | nil) :: [
          Supervisor.child_spec() | {module(), keyword()} | module()
        ]
  def children(services, keeper?, direct_launcher \\ Locus.Executor.direct_launcher())

  def children(
        %{builds: builds?, backends: backends?} = services,
        false = _keeper?,
        direct_launcher
      )
      when builds? or backends? do
    if direct_launcher do
      served(services, [build_slots()])
    else
      raise "[Locus] FATAL: a Locus node runs every build and every backend only through " <>
              "cyfr-keeper, which starts it with its channel on fd 3 (KEEPER_CHANNEL); fd 3 " <>
              "is not that channel. Start the release through `cyfr-keeper serve " <>
              pools(services) <> " -- /app/bin/locus start` (the image's entrypoint)."
    end
  end

  def children(services, keeper?, _direct_launcher) do
    served(services, [build_slots()] ++ if(keeper?, do: [Locus.Keeper], else: []))
  end

  defp served(%{builds: builds?, backends: backends?}, children) do
    children ++
      if(builds?, do: [listener()], else: []) ++
      if(backends?, do: Locus.Backends.children(), else: [])
  end

  defp pools(%{builds: builds?, backends: backends?}) do
    [if(builds?, do: "--pool build:…"), if(backends?, do: "--pool backends:…")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  @doc """
  The build slots, `Locus.BuildSlots`: one `Prima.Slots` instance whose caps
  are read once at boot, `Locus.Config.max_concurrent/0` in all and
  `Locus.Config.max_concurrent_per_tenant/0` for one athanor, keyed by a
  request's `athanor_id`. A build past either cap is refused, never queued:
  a backlog of multi-minute builds behind a waiting caller helps nobody.
  The connection serving a build holds its slot, so a connection that dies
  gives the slot back by its monitor.
  """
  @spec build_slots() :: {Prima.Slots, [Prima.Slots.option()]}
  def build_slots do
    {Prima.Slots,
     name: Locus.BuildSlots,
     max: Locus.Config.max_concurrent(),
     key_max: Locus.Config.max_concurrent_per_tenant(),
     child_reserve: 0,
     policy: :reject}
  end

  @doc """
  The builds service's listener on the address `Locus.Config` names, or on
  `opts` (`:ip`, `:port`) in its place: HTTP/1.1 alone, so a connection
  carries one request at a time and its socket is the one the service asks
  about its peer. In compose the container sits on the builds network
  alone, so every interface is that network; elsewhere `LOCUS_BUILDS_BIND`
  names the one address to listen on.
  """
  @spec listener(keyword()) :: {module(), keyword()}
  def listener(opts \\ []) do
    {Bandit,
     Keyword.merge(
       [
         plug: Locus.BuilderService,
         ip: Locus.Config.bind(),
         port: Locus.Config.port(),
         http_2_options: [enabled: false]
       ],
       opts
     )}
  end

  @doc false
  # The level and format `LOCUS_BUILDS_LOG_*` name, the node's whichever
  # service it serves, applied where the environment was read; the format
  # replaces only the default handler's, keeping the metadata roster the
  # release was configured with.
  def configure_logging do
    Logger.configure(level: Locus.Config.log_level())

    with {_module, _function} = format <- Locus.Config.log_formatter() do
      formatter =
        :logger
        |> Application.get_env(:default_formatter, [])
        |> Keyword.put(:format, format)
        |> Logger.Formatter.new()

      :logger.update_handler_config(:default, :formatter, formatter)
    end

    :ok
  end
end
