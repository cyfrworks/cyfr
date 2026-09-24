# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ProjectionReconciler do
  @moduledoc """
  Keeps the component domain's projections of the seeded roots — the
  component registry of `components/`, the agent index of `aqua/` — in
  step with the units under them, and holds every facade read of them to
  that: a read observes the rows the tree derives, or
  `{:error, :projection_unavailable}`, never a silently stale index.

  ## The contract it consumes

  Arca stamps every change of a unit under a seeded root with a
  generation, the root's new epoch, pending while its bytes move and
  ready once they are served (`Arca.StorageProjectionChanges`). The root's
  row says how far its projection has acknowledged. This module never
  reads a unit's bytes to learn whether it changed.

  ## The barrier

  `await/2` is what every facade read of a projection passes first: one
  consistent read of the root's epoch and the epoch its projection
  acknowledged. Equal, and the rows stand. Behind, and the read reconciles
  the root itself, in its own process, before it answers — so a read that
  follows a successful write observes that write with no notification
  delivered. A change still pending (a move not finished, a write not
  returned) older than `settle_after_ms` gets one repair attempt through
  the storage API (`Arca.Overlay.repair_unit/2`); a younger one is a
  writer still at work, and the read answers unavailable rather than race
  its move. What cannot be made ready answers
  `{:error, :projection_unavailable}`; a journal that names another
  revision stays so until the unit is dropped or republished. The read
  path never sleeps.

  ## Reconciliation

  `reconcile/3` takes a snapshot of the root (`Arca.StorageProjectionChanges.snapshot/3`),
  derives the rows of the units it names from the tree, and replaces them
  through the root's storage facade (`Arca.ComponentStorage.replace_projection/3`,
  `Arca.AgentStorage.replace_projection/4`), which acknowledges them in the
  same transaction or refuses the whole replacement as a generation
  conflict when anything under the root changed since the snapshot.
  Three conflicts answer `{:error, :projection_unavailable}` and leave the
  old rows and the pending changes for the next reader or the recovery.
  After each acknowledged replacement this node's execution caches for
  the athanor are swept, and a change touching `tinctures/` is announced
  on the athanor's tinctures topic.

  The component registry is replaced unit by unit
  (`Compendium.Registry.projection_plan/3`); the agent index is a whole
  rewrite from the tree (`Compendium.AgentIndex.derive/1`), so a unit
  pending under `aqua/` holds the whole rewrite back.

  ## The process

  Started after `Compendium.Provisioning` with `enabled: true`, it attaches
  to the storage change notification (`Cyfr.Telemetry.Catalog.consumed_by(:projection)`),
  whose handler only sends to this process's registered name, and
  reconciles the estate a ready change names. It recovers every estate a
  root is behind in once it has started (`handle_continue/2`, never
  `init/1`) and every `interval_ms` while this member holds its slot
  (`Arca.ControlPlane.held?/0`), settling first the changes whose writer
  is gone (`Arca.StorageProjectionChanges.settle_stale/3`). It takes no job
  claim: a replacement is generation-checked, and two members replacing
  one root replace it the same. Nothing here is required for a read to
  be right — a lost notification, a crashed or absent process costs the
  next reader a reconciliation.

  Configuration: `config :cyfr, Compendium.ProjectionReconciler` with
  `enabled`, `interval_ms` and `settle_after_ms`.
  """

  use GenServer

  require Logger

  alias Arca.{StorageProjectionChanges, StorageProjectionRoots}
  alias Sanctum.Context

  @roots ~w(components aqua)
  @conflicts 3
  @reconciling {__MODULE__, :reconciling}

  @defaults [enabled: true, interval_ms: :timer.minutes(1), settle_after_ms: :timer.seconds(60)]

  @type root :: String.t()

  # ---------------------------------------------------------------------------
  # The barrier
  # ---------------------------------------------------------------------------

  @doc """
  Hold a read of `root`'s projection until it reflects every change of the
  root: `:ok`, or `{:error, :projection_unavailable}` when a change cannot
  be made ready or three replacements conflicted. `{:error, :no_athanor}`
  for a context with no athanor, and the store's own error when it cannot
  answer.

  `opts` takes `settle_after_ms:` in place of the configured one. Inside a
  reconciliation of this process the reconciliation is the barrier, and
  `:ok` is answered at once.
  """
  @spec await(Context.t(), root(), keyword()) ::
          :ok | {:error, :projection_unavailable | :no_athanor | term()}
  def await(ctx, root, opts \\ [])

  def await(%Context{} = ctx, root, opts) when root in @roots and is_list(opts) do
    if Process.get(@reconciling) do
      :ok
    else
      case StorageProjectionRoots.epoch(Context.actor(ctx), root) do
        {:ok, %{epoch: epoch, acknowledged_epoch: epoch}} -> :ok
        {:ok, _behind} -> reconciled(reconcile(ctx, root, opts))
        {:error, _} = error -> error
      end
    end
  end

  defp reconciled({:ok, %{complete: true}}), do: :ok
  defp reconciled({:ok, _pending_left}), do: {:error, :projection_unavailable}
  defp reconciled({:error, _} = error), do: error

  @doc """
  The epoch `root`'s projection has acknowledged, after the barrier: what
  a cache derived from the root records beside what it derived, and
  compares on its next read (`Prism.TinctureRegistry`). `await: false`
  reads it as it stands, for a process that must not reconcile.
  """
  @spec acknowledged_epoch(Context.t(), root(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def acknowledged_epoch(%Context{} = ctx, root, opts \\ []) when root in @roots do
    if Keyword.get(opts, :await, true), do: _ = await(ctx, root)

    with {:ok, %{acknowledged_epoch: acknowledged}} <-
           StorageProjectionRoots.epoch(Context.actor(ctx), root),
         do: {:ok, acknowledged}
  end

  # ---------------------------------------------------------------------------
  # Reconciliation
  # ---------------------------------------------------------------------------

  @doc """
  Reconcile `root`'s projection for the context's athanor: snapshot,
  derive, replace, acknowledge — again on a generation conflict, three
  conflicts at most, then `{:error, :projection_unavailable}`.

  Options:

    * `units:` — unit keys to derive whether pending or not (a register
      of one unit, a scan of every unit).
    * `force:` — unit keys to write again even when their derivation is
      unchanged.
    * `claim:` — a provisioning claim the agent index is rewritten under
      (`Arca.AgentStorage.replace_projection/4`); `{:error, :claim_lost}`
      is answered, never retried.
    * `settle_after_ms:` — how old a pending change must be before it is
      given a repair attempt; the configured one by default.

  Answers `%{complete: boolean}` merged with the root's result: the
  registry's `outcomes` by unit key and the rows it `removed`, or the
  agent index's `rows`. `complete: false` says a pending change was left
  as it was.
  """
  @spec reconcile(Context.t(), root(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile(%Context{} = ctx, root, opts \\ []) when root in @roots and is_list(opts) do
    previous = Process.put(@reconciling, true)

    try do
      attempt(ctx, root, opts, 0, false)
    after
      if previous, do: :ok, else: Process.delete(@reconciling)
    end
  end

  # `repair_tried?` holds the one repair attempt to one per reconciliation,
  # across the retries of a conflict.
  defp attempt(ctx, root, opts, conflicts, repair_tried?) do
    actor = Context.actor(ctx)

    with {:ok, token} <-
           StorageProjectionChanges.snapshot(actor, root, units: Keyword.get(opts, :units, [])) do
      case Enum.reject(token.units, & &1.ready) do
        [] ->
          replace(ctx, root, token, opts, conflicts, repair_tried?)

        stuck when not repair_tried? ->
          if repair(actor, root, stuck, opts) > 0,
            do: attempt(ctx, root, opts, conflicts, true),
            else: held_back(ctx, root, token, opts, conflicts)

        _stuck ->
          held_back(ctx, root, token, opts, conflicts)
      end
    end
  end

  # A pending change that stays pending: the agent index is one rewrite of
  # the whole tree and waits for it; the registry replaces every unit that
  # is ready and leaves that one, and the root, unacknowledged.
  defp held_back(_ctx, "aqua", _token, _opts, _conflicts), do: {:error, :projection_unavailable}

  defp held_back(ctx, root, token, opts, conflicts),
    do: replace(ctx, root, token, opts, conflicts, true)

  defp replace(ctx, root, token, opts, conflicts, repair_tried?) do
    case project(ctx, root, token, opts) do
      {:ok, result} ->
        {:ok, Map.put(result, :complete, StorageProjectionChanges.complete?(token))}

      {:error, :generation_conflict} when conflicts + 1 >= @conflicts ->
        Logger.warning(
          "[Compendium.ProjectionReconciler] #{root} of #{token.athanor_id}: " <>
            "#{@conflicts} replacements conflicted; the pending changes stay for the next read"
        )

        {:error, :projection_unavailable}

      {:error, :generation_conflict} ->
        attempt(ctx, root, opts, conflicts + 1, repair_tried?)

      {:error, _} = error ->
        error
    end
  end

  # One repair attempt for each pending change old enough that its writer
  # is gone; a younger one is a move still running, never raced. Answers
  # how many were repaired.
  defp repair(actor, root, stuck, opts) do
    cutoff = DateTime.add(DateTime.utc_now(), -settle_after_ms(opts), :millisecond)

    Enum.count(stuck, fn %{unit_key: key, updated_at: at} ->
      at != nil and DateTime.compare(at, cutoff) != :gt and
        match?(
          {:ok, :repaired},
          Arca.Overlay.repair_unit(actor, Arca.Storage.UnitLocator.unit_path(root, key))
        )
    end)
  end

  defp project(ctx, "components", token, opts) do
    with {:ok, plan} <- Compendium.Registry.projection_plan(ctx, token, opts),
         {:ok, %{deleted: removed}} <-
           Arca.ComponentStorage.replace_projection(Context.actor(ctx), token, %{
             put: plan.put,
             delete: plan.delete
           }) do
      Compendium.Registry.projected(ctx, plan, removed)
      if tinctures?(token, plan), do: announce_tinctures(ctx)
      {:ok, %{outcomes: plan.outcomes, removed: removed}}
    end
  end

  defp project(ctx, "aqua", token, opts) do
    with {:ok, rows} <- Compendium.AgentIndex.derive(ctx),
         {:ok, replaced} <-
           Arca.AgentStorage.replace_projection(
             Context.actor(ctx),
             token,
             rows,
             Keyword.take(opts, [:claim])
           ) do
      Compendium.Registry.invalidate_executor_caches(ctx)
      {:ok, %{rows: replaced}}
    end
  end

  # A replacement that named a tincture's unit, or wrote or removed one's
  # row, is what the console's tincture cache follows.
  defp tinctures?(token, plan) do
    Enum.any?(token.units, &(&1.pending and tincture_key?(&1.unit_key))) or
      Enum.any?(plan.changed, &tincture_key?/1)
  end

  defp tincture_key?(key),
    do: String.starts_with?(key, Compendium.ComponentPath.type_plural("tincture") <> "/")

  # After the replacement committed: the console's tincture cache re-reads.
  defp announce_tinctures(%Context{} = ctx) do
    actor = Context.actor(ctx)
    Cyfr.Bus.broadcast(actor, Cyfr.Bus.tinctures(actor), Cyfr.Bus.Tinctures.new(actor, :changed))
  end

  defp settle_after_ms(opts),
    do: Keyword.get_lazy(opts, :settle_after_ms, fn -> config()[:settle_after_ms] end)

  defp config, do: Keyword.merge(@defaults, Application.get_env(:cyfr, __MODULE__, []))

  # ---------------------------------------------------------------------------
  # The process
  # ---------------------------------------------------------------------------

  @doc false
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Start the reconciler. Options override the configuration: `name:`
  (default this module), `enabled:`, `interval_ms:`, `settle_after_ms:`.
  A reconciler that is not enabled starts, attaches nothing and ticks
  nothing.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @impl true
  def init(opts) do
    config = Keyword.merge(config(), opts)

    state = %{
      name: Keyword.fetch!(config, :name),
      enabled: Keyword.fetch!(config, :enabled) == true,
      interval_ms: Keyword.fetch!(config, :interval_ms),
      settle_after_ms: Keyword.fetch!(config, :settle_after_ms)
    }

    if state.enabled do
      # Handlers are the node's, not this process's: detached when it
      # stops, and replaced when it starts again.
      Process.flag(:trap_exit, true)
      attach(state.name)
      {:ok, state, {:continue, :recover}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:recover, state) do
    recover(state)
    {:noreply, schedule(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    if Arca.ControlPlane.held?(), do: recover(state)
    {:noreply, schedule(state)}
  end

  def handle_info({:projection_changed, athanor_id, root, true}, state) do
    guarded("#{root} of #{athanor_id}", fn -> reconcile(estate(athanor_id), root) end)
    {:noreply, state}
  end

  # A change not yet ready is reconciled when it is marked ready.
  def handle_info({:projection_changed, _athanor_id, _root, false}, state),
    do: {:noreply, state}

  def handle_info(msg, state) do
    Cyfr.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{enabled: true, name: name}), do: detach(name)
  def terminate(_reason, _state), do: :ok

  @doc false
  # The notification's handler: a send to the registered name, and no
  # database. Runs in the process that committed the change.
  def handle_event(_event, %{epoch: _}, %{athanor_id: athanor_id, root: root, ready: ready}, %{
        name: name
      }) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> send(pid, {:projection_changed, athanor_id, root, ready})
    end

    :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  @doc false
  # Attach the handler for the reconciler registered as `name` to exactly
  # the catalog's `:projection` roster, replacing any earlier attach of it.
  @spec attach(atom()) :: :ok | {:error, term()}
  def attach(name) do
    detach(name)

    case :telemetry.attach_many(
           handler_id(name),
           Cyfr.Telemetry.Catalog.consumed_by(:projection),
           &__MODULE__.handle_event/4,
           %{name: name}
         ) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.error(
          "[Compendium.ProjectionReconciler] could not attach: #{inspect(reason)} — " <>
            "projections follow reads and the periodic recovery alone on this node"
        )

        error
    end
  end

  @doc false
  @spec detach(atom()) :: :ok
  def detach(name) do
    _ = :telemetry.detach(handler_id(name))
    :ok
  end

  @doc false
  @spec handler_id(atom()) :: {module(), atom()}
  def handler_id(name), do: {__MODULE__, name}

  defp schedule(state) do
    Process.send_after(self(), :tick, state.interval_ms)
    state
  end

  # Every estate a root is behind in: the writers gone are settled, then
  # the root is reconciled. One estate's failure is logged and the walk
  # goes on.
  defp recover(state) do
    # The one read across estates (`Cyfr.Boundaries.system_responsibilities/0`).
    case Arca.StorageProjectionChanges.pending_athanors(Cyfr.Actor.system()) do
      {:ok, athanors} ->
        for athanor_id <- athanors, root <- @roots do
          ctx = estate(athanor_id)

          guarded("#{root} of #{athanor_id}", fn ->
            _ =
              StorageProjectionChanges.settle_stale(Context.actor(ctx), root,
                settle_after_ms: state.settle_after_ms
              )

            reconcile(ctx, root, settle_after_ms: state.settle_after_ms)
          end)
        end

        :ok

      {:error, reason} ->
        Logger.warning(
          "[Compendium.ProjectionReconciler] pending estates could not be read: #{inspect(reason)}"
        )
    end
  end

  defp guarded(what, fun) do
    case fun.() do
      {:error, reason} ->
        Logger.info(
          "[Compendium.ProjectionReconciler] #{what} not reconciled: #{inspect(reason)}"
        )

      _reconciled ->
        :ok
    end
  rescue
    e ->
      Logger.error(
        "[Compendium.ProjectionReconciler] #{what} raised: " <>
          Exception.format(:error, e, __STACKTRACE__)
      )
  end

  # The server's own context inside one estate, reading its tree.
  defp estate(athanor_id) do
    Sanctum.internal_context(
      user_id: "_projection",
      athanor_id: athanor_id,
      scope: :athanor,
      permissions: [:storage_read]
    )
  end
end
