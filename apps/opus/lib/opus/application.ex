# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Application do
  @moduledoc """
  The `opus` application in either of its roles (`Opus.Release.role/0`).

  The service role runs the worker service tree (`Opus.WorkerService.Tree`:
  the runner pool with its keeper and the worker service, restarted
  together, so a restarted service is a new boot that monitors none of
  the old runners) and the listener CYFR reaches it through. It loads no
  component: the engine, its cache and its task supervisor start in the
  service's VM only under the `:local` keeper, where the service runs
  subtrees itself.

  The runner role runs the engine and the runner (`Opus.Runner`) that
  takes subtrees over its control channel, and no listener: a runner is
  reached by its service alone. Its log output goes to standard error, so
  standard output carries frames alone when the channel is there. The
  runner's end ends the VM (`Opus.Release`).
  """

  use Application

  @impl true
  def start(_type, _args) do
    case Opus.Release.role() do
      :service ->
        # The nonces the worker listener has seen, owned by the application
        # so a listener or service restart forgets none within the header
        # window.
        :ok = Opus.WorkerListener.init_nonces()
        settings = Opus.Settings.pool!()
        opts = [strategy: :one_for_one, name: Opus.Supervisor, max_restarts: 10, max_seconds: 60]
        Supervisor.start_link(children(:service, settings), opts)

      :runner ->
        :ok = Opus.Release.log_to_stderr()
        settings = Opus.Settings.runner!()
        # A runner is one job's VM: a child that fails is not restarted, the
        # VM ends instead, and the service reports what it assigned.
        opts = [strategy: :one_for_one, name: Opus.Supervisor, max_restarts: 0]
        Supervisor.start_link(children(:runner, settings), opts)
    end
  end

  @doc """
  The children of `Opus.Supervisor` in `role`, under its settings
  (`t:Opus.Settings.pool/0` for the service, `t:Opus.Settings.runner/0`
  for a runner).
  """
  @spec children(:service | :runner, map()) :: [
          Supervisor.child_spec() | {module(), term()} | module()
        ]
  def children(:service, %{keeper: keeper}) do
    engine = if keeper == :local, do: engine(), else: []

    engine ++
      [
        %{
          id: Opus.WorkerService.Tree,
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
        {DynamicSupervisor, name: Opus.Runner.attempts_supervisor(), strategy: :one_for_one},
        {Opus.Runner, settings: settings}
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
      Opus.SharedEngine,
      Opus.Cache,
      Supervisor.child_spec({Task.Supervisor, name: Opus.TaskSupervisor}, shutdown: 30_000)
    ]
  end

  @doc false
  # The service tree, built from the settings when it starts, so a restart
  # under other settings (a test's) takes them.
  def start_service_tree do
    settings = Opus.Settings.pool!()

    Supervisor.start_link(service_tree(settings),
      strategy: :one_for_all,
      name: Opus.WorkerService.Tree
    )
  end

  @doc "The children of `Opus.WorkerService.Tree` under `settings`, in start order."
  @spec service_tree(Opus.Settings.pool()) :: [
          Supervisor.child_spec() | {module(), term()} | module()
        ]
  def service_tree(%{keeper: :local}) do
    [
      {DynamicSupervisor, name: Opus.WorkerService.runners_supervisor(), strategy: :one_for_one},
      Opus.WorkerService
    ]
  end

  def service_tree(%{keeper: keeper} = settings) do
    module = Opus.Keeper.module(keeper)
    keeper_opts = [attach_dir: settings.attach_dir]
    :ok = Opus.Keeper.check!(module, keeper_opts)

    [
      {DynamicSupervisor, name: Opus.RunnerPool.Runners, strategy: :one_for_one},
      module.child_spec(keeper_opts),
      {Opus.RunnerPool,
       settings: settings,
       keeper: module,
       keeper_opts: keeper_opts,
       supervisor: Opus.RunnerPool.Runners},
      Opus.WorkerService
    ]
  end

  # The credentials are loaded by the worker service, which refuses the
  # boot when they are missing or malformed; the listener reads the same.
  defp listener do
    %Opus.Credentials{bind: bind, port: port} = Opus.Credentials.load!()

    Supervisor.child_spec({Bandit, plug: Opus.WorkerListener, ip: bind, port: port},
      id: Opus.WorkerListener
    )
  end
end
