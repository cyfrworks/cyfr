# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime do
  @moduledoc """
  The runtime role of Locus, in either of its forms
  (`Locus.Runtime.Release.role/0`). `Locus.Application` starts it.

  On a service node that holds the runtime's key, it is one child of
  `Locus.Supervisor`, `Locus.Runtime.Supervisor` (`children/1`), which
  runs the worker service tree (`Locus.Runtime.WorkerService.Tree`: the
  runner pool with its keeper and the worker service, restarted together,
  so a restarted service is a new boot that monitors none of the old
  runners) and the listener CYFR reaches it through. It loads no
  component, and starts no engine.

  A runner (`RUNTIME_ROLE=runner`) runs the engine and the runner
  (`Locus.Runtime.Runner`) that takes subtrees over its control channel,
  and no listener, as the application's own tree (`start_runner/0`): a
  runner is reached by its service alone and serves no role. Its log
  output goes to standard error, so standard output carries frames alone
  when the channel is there. The runner's end ends the VM
  (`Locus.Runtime.Release`).
  """

  @doc """
  The children `Locus.Application` starts for the runtime on a service
  node: one, `Locus.Runtime.Supervisor` (`start_service/0`).
  """
  @spec children(:service) :: [Supervisor.child_spec()]
  def children(:service) do
    [
      %{
        id: Locus.Runtime.Supervisor,
        type: :supervisor,
        start: {__MODULE__, :start_service, []}
      }
    ]
  end

  @doc """
  Start `Locus.Runtime.Supervisor` on a service node. A service whose
  settings refuse, or whose keeper cannot run here, starts no runner: the
  start is refused before anything starts, naming cyfr-locus when no
  channel was inherited, and with it the node's boot.
  """
  @spec start_service() :: Supervisor.on_start()
  def start_service do
    settings = Locus.Runtime.Settings.pool!()
    :ok = keeper!(settings)
    # The nonces the worker listener has seen, owned above this supervisor
    # so a listener or service restart forgets none within the header
    # window.
    :ok = Locus.Runtime.WorkerListener.init_nonces()

    Supervisor.start_link(children(:service, settings),
      strategy: :one_for_one,
      name: Locus.Runtime.Supervisor,
      max_restarts: 10,
      max_seconds: 60
    )
  end

  @doc """
  Start a runner's tree, as the application's own supervisor: the runner
  role reads its settings from its environment alone and serves nothing.
  """
  @spec start_runner() :: Supervisor.on_start()
  def start_runner do
    :ok = Locus.Runtime.Release.log_to_stderr()
    settings = Locus.Config.runner!()

    # A runner is one job's VM: a child that fails is not restarted, the VM
    # ends instead, and the service reports what it assigned.
    Supervisor.start_link(children(:runner, settings),
      strategy: :one_for_one,
      name: Locus.Runtime.Supervisor,
      max_restarts: 0
    )
  end

  @doc """
  The children of `Locus.Runtime.Supervisor` in `role`, under its settings
  (`t:Locus.Runtime.Settings.pool/0` for the service, `t:Locus.Runtime.Settings.runner/0`
  for a runner).
  """
  @spec children(:service | :runner, map()) :: [
          Supervisor.child_spec() | {module(), term()} | module()
        ]
  def children(:service, _settings) do
    [
      %{
        id: Locus.Runtime.WorkerService.Tree,
        type: :supervisor,
        start: {__MODULE__, :start_service_tree, []}
      },
      # Where CYFR reaches the worker service, on the address its
      # credentials name. Started after the service, so a request never
      # finds it absent.
      listener()
    ]
  end

  def children(:runner, settings) do
    engine() ++
      [
        {DynamicSupervisor,
         name: Locus.Runtime.Runner.attempts_supervisor(), strategy: :one_for_one},
        {Locus.Runtime.Runner, settings: settings}
      ]
  end

  @doc """
  What runs guest code: the shared Wasmex engine for
  compile-once/instantiate-many, its disposable state
  (compiled components and open streams), and the supervised
  fire-and-forget tasks (a guest's streaming HTTP request).
  """
  @spec engine() :: [Supervisor.child_spec() | module()]
  def engine do
    [
      Locus.Runtime.SharedEngine,
      Locus.Runtime.Cache,
      Supervisor.child_spec({Task.Supervisor, name: Locus.Runtime.TaskSupervisor},
        shutdown: 30_000
      )
    ]
  end

  @doc false
  # The service tree, built from the settings when it starts, so a restart
  # under other settings (a test's) takes them.
  def start_service_tree do
    settings = Locus.Runtime.Settings.pool!()

    Supervisor.start_link(service_tree(settings),
      strategy: :one_for_all,
      name: Locus.Runtime.WorkerService.Tree
    )
  end

  @doc "The children of `Locus.Runtime.WorkerService.Tree` under `settings`, in start order."
  @spec service_tree(Locus.Runtime.Settings.pool()) :: [
          Supervisor.child_spec() | {module(), term()} | module()
        ]
  def service_tree(%{keeper: keeper} = settings) do
    module = Locus.Runtime.Keeper.module(keeper)
    :ok = Locus.Runtime.Keeper.check!(module, [])

    [
      {DynamicSupervisor, name: Locus.Runtime.RunnerPool.Runners, strategy: :one_for_one},
      module.child_spec([]),
      {Locus.Runtime.RunnerPool,
       settings: settings,
       keeper: module,
       keeper_opts: [],
       supervisor: Locus.Runtime.RunnerPool.Runners},
      Locus.Runtime.WorkerService
    ]
  end

  @doc """
  Whether the keeper `settings` name can run where `inherited?` says
  whether cyfr-locus's channel was inherited
  (`Locus.Keeper.channel_inherited?/0` by default), raising when it
  cannot: the service's boot check. The channel keeper's refusal names
  `cyfr-locus`.
  """
  @spec keeper!(Locus.Runtime.Settings.pool(), boolean()) :: :ok
  def keeper!(%{keeper: keeper}, inherited? \\ Locus.Keeper.channel_inherited?()) do
    Locus.Runtime.Keeper.check!(Locus.Runtime.Keeper.module(keeper), [], inherited?)
  end

  # The credentials are loaded by the worker service, which refuses the
  # boot when they are missing or malformed; the listener reads the same.
  # HTTP/1.1 alone, as the builds and backends listeners serve;
  # runtime_http2_test.exs holds it.
  defp listener do
    %Locus.Runtime.Credentials{bind: bind, port: port} = Locus.Runtime.Credentials.load!()

    Supervisor.child_spec(
      {Bandit,
       plug: Locus.Runtime.WorkerListener, ip: bind, port: port, http_2_options: [enabled: false]},
      id: Locus.Runtime.WorkerListener
    )
  end
end
