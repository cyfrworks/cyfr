# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Application do
  @moduledoc """
  The builder's supervision tree, in dependency order: the build slots,
  the client of cyfr-spawn when this node was started by it, and the
  builds service's listener when this node serves builds.

  A node serves builds when it holds a builds key
  (`Locus.Config.request_key/0`): the `locus` release always does, since
  its boot refuses without one (`config/locus_runtime.exs`), and a node
  whose environment was never read serves none. A node that serves runs
  every build through cyfr-spawn, under a uid and a memory bound of the
  build's own, so serving without the spawner's channel refuses the boot.
  The one build that serves without it is the test environment's, through
  `Locus.DirectLauncher`, and that choice is compiled into no other
  (`Locus.Executor.executors/0`): no setting of a release reaches it.

  The tree restarts `:rest_for_one`. The listener depends on the spawner:
  when cyfr-spawn's channel is lost the spawner stops, the listener stops
  with it, and a spawner that cannot come back ends the application, and
  with it the release.
  """

  use Application

  @impl true
  def start(_type, _args) do
    serve? = Locus.Config.request_key() != nil
    keeper? = Locus.Spawner.channel_inherited?()

    if serve?, do: configure_logging()

    # The nonces the service has seen, owned by the application so a
    # listener restart forgets none within the header window.
    :ok = Locus.BuilderService.init_nonces()

    Supervisor.start_link(children(serve?, keeper?),
      strategy: :rest_for_one,
      name: Locus.Supervisor
    )
  end

  @doc """
  The children of `Locus.Supervisor` for a node that serves builds or does
  not, started by cyfr-spawn or not, under the executors this build knows.
  Serving without the spawner where the direct launcher is unknown raises:
  the boot is refused.
  """
  @spec children(boolean(), boolean(), [module()]) :: [
          Supervisor.child_spec() | {module(), keyword()} | module()
        ]
  def children(serve?, keeper?, executors \\ Locus.Executor.executors())

  def children(true = _serve?, false = _keeper?, executors) do
    if Locus.DirectLauncher in executors do
      [build_slots(), listener()]
    else
      raise "[Locus] FATAL: the builds service runs a build only through cyfr-spawn, which " <>
              "starts it with its channel on fd 3 (CYFR_SPAWN_CHANNEL); fd 3 is not that " <>
              "channel. Start the release through `cyfr-spawn serve --pool build:… -- " <>
              "/app/bin/locus start` (the image's entrypoint)."
    end
  end

  def children(serve?, keeper?, _executors) do
    [build_slots()] ++
      if(keeper?, do: [Locus.Spawner], else: []) ++
      if(serve?, do: [listener()], else: [])
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
  # The level and format `LOCUS_BUILDS_LOG_*` name, applied where the
  # environment was read; the format replaces only the default handler's,
  # keeping the metadata roster the release was configured with.
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
