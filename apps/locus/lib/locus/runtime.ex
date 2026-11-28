# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime do
  @moduledoc """
  The runtime role of Locus. `Locus.Application` starts it.

  On a service node that holds the runtime's key, it is one child of
  `Locus.Supervisor`, `Locus.Runtime.Supervisor` (`children/1`), which
  runs the worker service tree (`Locus.Runtime.WorkerService.Tree`: the
  runner pool with its keeper, the forwarder of its runners' operator
  events and the worker service) and the listener CYFR reaches it
  through. Neither supervisor restarts a child
  (`Locus.Application.tree_options/0`): the pool holds the account of the
  runners cyfr-locus holds for it, so its end, or any child's, ends the
  node. It loads no component, and runs no guest code.

  A runner is the runner program (`apps/locus/runner`, at
  `Locus.Runtime.Settings.runner_command/0`), started through the
  service's keeper: it reads its control channel and its relay and runs
  every subtree it is assigned, and is reached by its service alone. A
  guest in a runner sits inside four bounds, each holding without the
  others: the engine's WebAssembly sandbox, the runner's pooled uid, the
  cgroup that bounds its memory, and the network namespace whose only way
  out is the relay.
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
    # The nonces the worker listener has seen, made before this supervisor
    # so the listener finds its table from its first request.
    :ok = Locus.Runtime.WorkerListener.init_nonces()

    Supervisor.start_link(
      children(:service, settings),
      [name: Locus.Runtime.Supervisor] ++ supervisor_options(:service)
    )
  end

  @doc """
  The options a service node's runtime supervisor is started with beside
  its name, `:service`'s (`Locus.Runtime.Supervisor`) and `:worker`'s (the
  worker service tree): the node's (`Locus.Application.tree_options/0`).
  """
  @spec supervisor_options(:service | :worker) :: [Supervisor.init_option()]
  def supervisor_options(supervisor) when supervisor in [:service, :worker],
    do: Locus.Application.tree_options()

  @doc """
  The children of `Locus.Runtime.Supervisor` on a service node, under its
  settings (`t:Locus.Runtime.Settings.pool/0`).
  """
  @spec children(:service, Locus.Runtime.Settings.pool()) :: [
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

  @doc false
  # The service tree, built from the settings when it starts, so a restart
  # under other settings (a test's) takes them.
  def start_service_tree do
    settings = Locus.Runtime.Settings.pool!()

    Supervisor.start_link(
      service_tree(settings),
      [name: Locus.Runtime.WorkerService.Tree] ++ supervisor_options(:worker)
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
      # Before the pool, whose runners' handles forward to it.
      Locus.Runtime.Events,
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
