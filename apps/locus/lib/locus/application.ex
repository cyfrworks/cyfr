# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Application do
  @moduledoc """
  A Locus node's supervision tree.

  A boot whose environment says `RUNTIME_ROLE=runner` is a runner of the
  runtime role (`Locus.Runtime.Release.role/0`): the keeper started it for
  one runtime service, and it runs the runner's tree alone
  (`Locus.Runtime.start_runner/0`) and serves no role. Every other boot is
  a service node.

  A service node serves each role whose key it holds: the runtime with a
  runtime key (the `:service_key` of `config :locus, :runtime`), builds
  with a builds key (`Locus.Config.request_key/0`), backends with a
  backends key (`Locus.Config.backends_key/0`). The `locus` release holds
  at least one, since its boot refuses without any
  (`config/locus_runtime.exs`). A node that holds the runtime key and
  either other key refuses to boot (`roles!/1`): the runtime, whose
  runners have no network, never shares a node, a key or a network with
  a role that has open egress. A node whose environment was never read
  serves none, or the runtime alone where the configuration gives it a
  key (a `mix` boot, the test suite).

  A node that serves runs every runner, build and backend through
  cyfr-locus, each under a uid and a memory bound of its own, so serving
  without the keeper's channel refuses the boot. The test build alone
  serves without it, through the direct launcher its test support
  compiles (`Locus.Executor.direct_launcher/0`, and its runtime face,
  `Locus.Runtime.Keeper.direct_keeper/0`), which no other build compiles:
  no setting of a release reaches it.

  The tree restarts `:rest_for_one`, in dependency order: the build
  slots, the one client of cyfr-locus (`Locus.Keeper`) when this node was
  started by it, whatever roles it serves (a runtime node's attaches its
  runners' relays in the runtime's attach directory), the runtime
  (`Locus.Runtime.children/1`) when it is served, the builds service's
  listener when builds are served, and the backends service's children
  (`Locus.Backends.children/0`) when backends are. When cyfr-locus's
  channel is lost its client stops, everything started after it stops
  with it, and a client that cannot come back ends the application, and
  with it the release.
  """

  use Application

  @impl true
  def start(_type, _args) do
    # Before the role is read, so that a service node's and a runner's log
    # events have their stack frames reduced to their arity from the first
    # (`Prima.LogFilter`).
    :ok = Prima.LogFilter.install()

    case Locus.Runtime.Release.role() do
      :runner -> Locus.Runtime.start_runner()
      :service -> start_node()
    end
  end

  defp start_node do
    roles = node_roles!(Application.get_all_env(:locus))
    keeper? = Locus.Keeper.channel_inherited?()
    :ok = release_logging(roles)

    # The nonces each service has seen, owned by the application so a
    # listener restart forgets none within the header window.
    :ok = Locus.BuilderService.init_nonces()
    :ok = Locus.Backends.init_nonces()

    Supervisor.start_link(children(roles, keeper?),
      strategy: :rest_for_one,
      name: Locus.Supervisor
    )
  end

  @typedoc "Which roles a service node serves."
  @type roles :: %{runtime: boolean(), builds: boolean(), backends: boolean()}

  @doc false
  # The roles a node whose `:locus` application environment is `env`
  # serves (`roles!/1`): the runtime with the runtime's key, builds with a
  # builds key, backends with a backends key.
  @spec node_roles!(keyword()) :: roles()
  def node_roles!(env) when is_list(env) do
    roles!(%{
      runtime: get_in(env, [:runtime, :service_key]) != nil,
      builds: Keyword.get(env, :request_key) != nil,
      backends: Keyword.get(env, :backends_key) != nil
    })
  end

  @doc false
  # The release's one log setting, applied on a release node whatever role
  # it serves. `config/locus_runtime.exs` is the only writer of
  # `:log_level` and it writes it on every boot it lets through, so the key
  # is set exactly when this is a release boot. A `mix` boot or the test
  # suite never reads that file and keeps the logger its config files set,
  # its in-VM runtime included. A runner never comes here
  # (`Locus.Runtime.start_runner/0`).
  @spec release_logging(roles()) :: :ok
  def release_logging(roles) do
    if served?(roles) and Application.fetch_env(:locus, :log_level) != :error,
      do: configure_logging(),
      else: :ok
  end

  @doc """
  The roles a service node serves, from which keys it holds, raising when
  it holds the runtime key and either other key: the refusal names
  `LOCUS_RUNTIME_KEY` and each other key variable held.
  """
  @spec roles!(roles()) :: roles()
  def roles!(%{runtime: runtime?, builds: builds?, backends: backends?} = roles)
      when is_boolean(runtime?) and is_boolean(builds?) and is_boolean(backends?) do
    if runtime? and (builds? or backends?) do
      held =
        [if(builds?, do: "LOCUS_BUILDS_KEY"), if(backends?, do: "LOCUS_BACKENDS_KEY")]
        |> Enum.reject(&is_nil/1)

      raise ArgumentError,
            "[Locus] FATAL: a node holding LOCUS_RUNTIME_KEY serves the runtime alone, and " <>
              "this one also holds #{Enum.join(held, " and ")}: the runtime's runners have " <>
              "no network, so it shares no node, key or network with a role that has open " <>
              "egress. Give each role a container of its own (docker-compose.yml's " <>
              "locus-runtime, locus-builds and locus-backends)."
    end

    roles
  end

  defp served?(%{runtime: runtime?, builds: builds?, backends: backends?}),
    do: runtime? or builds? or backends?

  @doc """
  The children of `Locus.Supervisor` for a node that serves `roles`,
  started by cyfr-locus or not, under the direct launcher this build has
  (`Locus.Executor.direct_launcher/0`, `nil` in every build but the test
  one's). Serving builds or backends without the keeper and without a
  direct launcher raises: the boot is refused. The runtime checks its own
  keeper when its supervisor starts (`Locus.Runtime.start_service/0`).
  """
  @spec children(roles(), boolean(), module() | nil) :: [
          Supervisor.child_spec() | {module(), keyword()} | module()
        ]
  def children(roles, keeper?, direct_launcher \\ Locus.Executor.direct_launcher())

  def children(
        %{builds: builds?, backends: backends?} = roles,
        false = _keeper?,
        direct_launcher
      )
      when builds? or backends? do
    if direct_launcher do
      served(roles, [build_slots()])
    else
      raise "[Locus] FATAL: a Locus node runs every build and every backend only through " <>
              "cyfr-locus, which starts it with its channel on fd 3 (KEEPER_CHANNEL); fd 3 " <>
              "is not that channel. Start the release through `cyfr-locus serve " <>
              pools(roles) <> " -- /app/bin/locus start` (the image's entrypoint)."
    end
  end

  def children(roles, keeper?, _direct_launcher) do
    served(roles, [build_slots()] ++ if(keeper?, do: [keeper(roles)], else: []))
  end

  # The client of cyfr-locus, every role's: a runtime node's attaches its
  # runners' relays where the runtime's settings say
  # (`LOCUS_RUNTIME_ATTACH_DIR`), builds and backends at its default.
  defp keeper(%{runtime: true}),
    do: {Locus.Keeper, attach_dir: Locus.Runtime.Settings.pool!().attach_dir}

  defp keeper(_roles), do: Locus.Keeper

  defp served(%{runtime: runtime?, builds: builds?, backends: backends?}, children) do
    children ++
      if(runtime?, do: Locus.Runtime.children(:service), else: []) ++
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
  # The level and format `LOCUS_LOG_*` name, the node's whichever role it
  # serves, applied where the environment was read; the format replaces
  # only the default handler's, keeping the metadata roster the release was
  # configured with.
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
