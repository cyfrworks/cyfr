# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.Supervisor do
  @moduledoc """
  The execution domain's processes: the slots, the attempt tree, the
  background roots, the watches and sweeper, and the host API listener.
  `rest_for_one`, because the watches, the sweeper and the listener read
  the attempt registries and the slots before them, and the listener must
  never outlive a fresh attempt tree: a restart of either restarts every
  child after it.

  Options, given by the composition root, which reads the configuration:
  `slot_caps` (`{max, key_max}`, the execution slots' caps), `bind` and
  `port` (where the host API listener binds), and `drain_ms` (how long
  the listener lets an open host call finish once it stops accepting).
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    {max, key_max} = Keyword.fetch!(opts, :slot_caps)

    Supervisor.init(
      [
        # Execution admission: the slots a member's own work holds, keyed
        # by athanor. The consented rate has no child here — its window is
        # a row every member of the cell claims in (`Arca.RateWindows`), so
        # there is nothing in this boot to start, own or lose. 5 s: its
        # terminate reporting the holdings it drops.
        Supervisor.child_spec({Prima.Slots, name: Crucible.Slots, max: max, key_max: key_max},
          shutdown: 5_000
        ),
        # Execution bookkeeping, after PubSub (the buffers broadcast on it):
        # the execution_id → driving-process registry, the per-execution
        # event-buffer registry, the emit counter, the buffers, and the open
        # attempts' registry and supervisor. The counter comes before the
        # buffers, so a restart of this group rebuilds the numbering source
        # first and then the buffers that read it; the attempts, which push
        # onto the buffers, come last; a dead registry restarts what
        # registers in it. The counter's 5 s is its stop, which holds no work
        # in flight.
        group(Crucible.Tree, [
          {Registry, keys: :unique, name: Crucible.Registry},
          {Registry, keys: :unique, name: Crucible.Events.Registry},
          Supervisor.child_spec(Crucible.Events.Sequence, shutdown: 5_000),
          {DynamicSupervisor, name: Crucible.Events.Supervisor, strategy: :one_for_one},
          {Registry, keys: :unique, name: Crucible.Attempt.Registry},
          {DynamicSupervisor, name: Crucible.Attempt.Supervisor, strategy: :one_for_one}
        ]),
        # Roots run in the background (`execution.run_stream`), after the
        # registry each one registers in. 30 s: the longest root it lets
        # finish.
        Supervisor.child_spec({Task.Supervisor, name: Crucible.TaskSupervisor},
          shutdown: 30_000
        ),
        # Stops an archived athanor's running work. The archive announces and
        # this reacts: what is still running is the execution domain's, and
        # the identity domain must not name it. 5 s: its stop, which holds no
        # work in flight.
        Supervisor.child_spec(Crucible.ArchiveWatch, shutdown: 5_000),
        # Periodic sweep that fails running executions whose lease lapsed;
        # started only when `:execution_sweeper_enabled`. 5 s: its stop,
        # which holds no work in flight.
        Supervisor.child_spec(Crucible.Sweeper, shutdown: 5_000),
        # Hears from each configured worker service every poll interval and
        # lapses what a boot it stopped hearing from, or saw replaced, was
        # running; started only when `:worker_watch_enabled`, which follows
        # `:execution_sweeper_enabled`. 5 s: its terminate releasing the
        # claims it holds.
        Supervisor.child_spec(Crucible.WorkerWatch, shutdown: 5_000),
        # The host API: where the worker services post their runners' host
        # calls, which each service verifies and relays, and their exit
        # reports. After the attempt tree
        # it serves, so a shutdown stops taking calls before the attempts
        # they reach go, and drains the calls already open for `drain_ms`.
        {Crucible.HostListener,
         bind: Keyword.fetch!(opts, :bind),
         port: Keyword.fetch!(opts, :port),
         drain_ms: Keyword.fetch!(opts, :drain_ms)}
      ],
      strategy: :rest_for_one,
      max_restarts: 10,
      max_seconds: 60
    )
  end

  # A registry and the processes that hold references into it restart
  # together: :rest_for_one from the registry (or table owner) down, so a
  # restart never leaves dependents holding a name that resolves to
  # nothing.
  defp group(name, children) do
    %{
      id: name,
      start:
        {Supervisor, :start_link,
         [children, [strategy: :rest_for_one, name: name, max_restarts: 10, max_seconds: 60]]},
      type: :supervisor
    }
  end
end
