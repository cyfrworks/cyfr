# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Cluster.Boot do
  @moduledoc """
  What runs **on** a member: bringing the whole `:cyfr` application up,
  giving it a worker service of its own, and the two cuts a case can make
  from inside it.

  Nothing here is a stand-in for the product's boot. `Application.ensure_all_started/1`
  starts the same supervision tree a release starts, under the same
  refusals: `Cyfr.Cell` reads `Cyfr.Cell.facts/0` and raises if this
  deployment cannot form a cell, the member claims its `cell_leases`
  slot, and `Cyfr.Bootstrap` reconciles the operators under that slot
  before anything that admits work — a refused reconcile is a boot that
  answers `{:error, reason}` here.

  A worker service is **not** started with the application. It is the
  suite's scripted one (`Cyfr.Test.ScriptedWorker`), served over HTTP on a
  loopback port of this member's own and holding keys derived from the
  shared worker root, and it is started by the case that needs it, with
  the reference and script that case scripts. One per member is what makes
  the workers **independently reachable**: a member can be cut off from a
  worker its peer can still hear.
  """

  @compile {:no_warn_undefined, [Cyfr.Test.ScriptedWorker, Cyfr.Test.ScriptedWorkerListener]}

  @doc """
  Start the application on this member. Answers `:ok`, or `{:error,
  reason}` naming what stopped the boot — a member that cannot form a
  cell raises here, and its refusal is what the case reads.
  """
  @spec start!(String.t()) :: :ok | {:error, term()}
  def start!(_worker_service) do
    case Application.ensure_all_started(:cyfr) do
      {:ok, _started} ->
        settle()
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  catch
    kind, reason -> {:error, {kind, reason, __STACKTRACE__}}
  end

  # A boot's own background work finishes before the member is handed to
  # a case. `Cyfr.RetentionScheduler` runs a cycle from
  # `handle_continue(:first_run, …)`, which is a boot of the product doing
  # exactly what it should — and a case that started beside it would be
  # racing a claim nobody asked for. `:sys.get_state/1` is the wait: the
  # scheduler answers it only once the continue has returned.
  defp settle do
    case Process.whereis(Cyfr.RetentionScheduler) do
      nil -> :ok
      pid -> :sys.get_state(pid, 120_000)
    end

    :ok
  end

  @doc """
  Start this member's scripted worker service for `opts` (`:ref` and
  `:script` at least), and answer the endpoint dispatch reaches it at.
  """
  @spec start_worker!(keyword()) :: map()
  def start_worker!(opts) do
    stop_worker!()
    {:ok, pid} = Cyfr.Test.ScriptedWorker.start_link(opts)
    detach(pid)
    Cyfr.Test.ScriptedWorker.endpoint()
  end

  @doc "Stop this member's scripted worker service, if it is running."
  @spec stop_worker!() :: :ok
  def stop_worker! do
    case Process.whereis(Cyfr.Test.ScriptedWorker) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  @doc "Replace what this member's scripted worker will answer next."
  @spec script!([term()]) :: :ok
  def script!(items), do: Cyfr.Test.ScriptedWorker.script(items)

  @doc """
  Point this member's dispatch at `endpoints` for `references` and at
  nothing else, so a case decides which worker each member reaches.
  """
  @spec route!([String.t()], [map()]) :: :ok
  def route!(references, endpoints) do
    Application.put_env(
      :cyfr,
      :locus_runtime_workers,
      Enum.map(endpoints, &Map.put(&1, :components, references))
    )

    :ok
  end

  @doc "Whether this member holds its cell slot, and under which generation."
  @spec standing() :: %{held: boolean(), generation: term(), boot: String.t(), node: node()}
  def standing do
    %{
      held: Arca.ControlPlane.held?(),
      generation: Arca.ControlPlane.generation(),
      boot: Prima.Boot.id(),
      node: node()
    }
  end

  @doc "This member's copy of the roster, and what it proposes for `subject`."
  @spec proposal(String.t()) :: %{roster: [String.t()], mine: boolean(), owner: term()}
  def proposal(subject) do
    %{
      roster: Cyfr.Cell.roster(),
      mine: Cyfr.Cell.mine?(subject),
      owner: Cyfr.Cell.owner_of(subject)
    }
  end

  @doc """
  Run one retention tick on this member, exactly as its own timer would,
  and answer once it has finished.

  The tick is the gated path — it asks the cell whether this member is the
  proposed owner before it asks for the claim row — and it is private, so
  it is driven through the message its timer sends. `:sys.get_state/1`
  after it is what makes this synchronous: the scheduler handles messages
  in order, so a reply to the second is proof the first has returned.
  """
  @spec retention_tick() :: :ok
  def retention_tick do
    send(Cyfr.RetentionScheduler, :run_cleanup)
    _settled = :sys.get_state(Cyfr.RetentionScheduler)
    :ok
  end

  @doc """
  Watch an execution's event stream from this member, keeping what
  arrives so a case can read it back (`stream_heard/0`).

  A stream's topic is the cell's, not a member's: a reader attached here
  follows an execution running on a peer. The watcher is a named process
  rather than the calling one, because the call that starts it returns.

  It answers only once that process has **subscribed**, and only once any
  watcher it replaced is gone: the subscription is made inside the
  watcher, so a case that published as soon as this returned would be
  waiting on events nobody was listening for yet.
  """
  @spec watch_stream!(String.t(), String.t()) :: :ok
  def watch_stream!(athanor_id, execution_id) do
    stop_stream_watch!()
    caller = self()

    watcher =
      spawn(fn ->
        :ok = Opus.subscribe_events(execution_id, %{athanor_id: athanor_id})
        send(caller, {:subscribed, self()})
        collect([])
      end)

    Process.register(watcher, :cyfr_cluster_stream_watch)

    receive do
      {:subscribed, ^watcher} -> :ok
    after
      10_000 -> raise "the stream watcher never subscribed to #{execution_id}"
    end
  end

  defp stop_stream_watch!, do: stop_registered!(:cyfr_cluster_stream_watch)

  # The name is one process's, and `Process.exit/2` is asynchronous, so a
  # replacement registered before the old watcher died would raise.
  defp stop_registered!(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        reference = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^reference, :process, ^pid, _reason} -> :ok
        after
          5_000 -> :ok
        end
    end
  end

  @doc "The sequences this member's stream watcher has heard, in arrival order."
  @spec stream_heard() :: [String.t()]
  def stream_heard do
    send(:cyfr_cluster_stream_watch, {:heard, self()})

    receive do
      {:heard, seen} -> seen
    after
      5_000 -> []
    end
  end

  defp collect(seen) do
    receive do
      %Cyfr.Bus.ExecutionEvent{sequence: sequence} ->
        collect(seen ++ [sequence])

      {:heard, from} ->
        send(from, {:heard, seen})
        collect(seen)

      _other ->
        collect(seen)
    end
  end

  @doc """
  Run one sweep of the stale-attempt pass on this member, as its own timer
  would (`Opus.Sweeper.sweep/0`).
  """
  @spec sweep() :: :ok
  def sweep, do: Opus.Sweeper.sweep()

  # ---------------------------------------------------------------------------
  # The worker watch
  # ---------------------------------------------------------------------------

  @watch :cyfr_cluster_worker_watch

  @doc """
  Watch `endpoint` from this member, on a watch of this case's own.

  The boot's own watch is started with no workers, so it polls nothing and
  writes nothing; this one names a service and a URL, which is how a case
  gives two members **different paths to one worker service** — the only
  way to tell a member that cannot hear a worker from a worker that is
  gone.
  """
  @spec watch_worker!(map(), keyword()) :: :ok
  def watch_worker!(endpoint, opts) do
    stop_watch!()

    {:ok, pid} =
      Opus.WorkerWatch.start_link(
        Keyword.merge(
          [
            name: @watch,
            workers: [endpoint],
            poll_ms: 1_000,
            misses: 3,
            lease_ms: 2_000
          ],
          opts
        )
      )

    detach(pid)
    :ok
  end

  # Everything a case starts on a member is started from inside a `:peer`
  # call, and that call runs in a process that exits the moment it
  # answers. A linked child would go with it, leaving the case watching a
  # worker service or a watch that stopped before the first assertion.
  defp detach(pid) do
    Process.unlink(pid)
    :ok
  end

  @doc "What this member's case watch has seen of each service."
  @spec watch_seen() :: map()
  def watch_seen do
    case Process.whereis(@watch) do
      nil -> %{}
      pid -> GenServer.call(pid, :seen)
    end
  end

  @doc "Stop this member's case watch, giving up every claim it holds."
  @spec stop_watch!() :: :ok
  def stop_watch! do
    case Process.whereis(@watch) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  @doc """
  A schedule of `athanor_id` that keeps its outcome as a note, bound to a
  profile of its own whose head consent is at revision 1, made on this
  member. Answers its id.
  """
  @spec keeping_schedule!(String.t(), String.t()) :: String.t()
  def keeping_schedule!(athanor_id, label) do
    profile_id = "prof-notes-#{label}-#{System.unique_integer([:positive])}"
    ref = "reagent:local.cluster-notes"

    :ok =
      Sanctum.Test.ConsentFixtures.seed_head!(
        %{Sanctum.TestContext.local() | athanor_id: athanor_id},
        %{id: profile_id, kind: :owner, source_ref: ref, label: "default", status: :active},
        %{
          id: "cons-#{profile_id}",
          revision: 1,
          scope: :versionless,
          pinned_version: "",
          invoke_mode: :open_inert,
          shape_digest: "sha256:shape-#{profile_id}",
          commit_digest: "sha256:commit-#{profile_id}",
          resolved_policy: Jason.encode!(%{"canonical" => "jcs-1", "nodes" => %{}}),
          activation: %{},
          admitted_origins: [:schedule],
          vault_refs: []
        }
      )

    {:ok, schedule} =
      Arca.CronSchedule.create(Prima.Actor.in_athanor(athanor_id), %{
        user_id: "usr_cluster",
        athanor_id: athanor_id,
        name: "cluster-notes-#{label}",
        cron_expression: "0 * * * *",
        reference: ref <> ":1.0.0",
        resolved_reference: ref <> ":1.0.0",
        profile_id: profile_id,
        metadata: Jason.encode!(%{"keep_outcome" => true}),
        next_run_at: DateTime.add(DateTime.utc_now(), -60, :second),
        cap: 1_000
      })

    schedule.id
  end

  @doc """
  One run of `schedule_id` on this member, ended as a completed run ends
  (`Opus.Schedules.Scheduler.complete/4`): its occurrence claimed under
  this member's slot and boot, started under a fresh execution as an
  admission starts it, and finished with `output`, the outcome's record
  written in the finish's own transaction. Answers the occurrence's id.
  """
  @spec finished_run!(String.t(), String.t(), term()) :: String.t()
  def finished_run!(athanor_id, schedule_id, output) do
    actor = Prima.Actor.in_athanor(athanor_id)
    {:ok, schedule} = Arca.CronSchedule.get(actor, schedule_id)
    cadence = %{next_after: &{:ok, DateTime.add(&1, 3600, :second)}, missed_bound_ms: 600_000}
    {:ok, occurrence} = Arca.ScheduleOccurrences.claim(schedule, Prima.Boot.id(), cadence)
    execution_id = Prima.UUID7.execution_id()

    {:ok, 1} =
      Arca.Repo.transaction(fn ->
        Arca.ScheduleOccurrences.start!(actor, occurrence.id, Prima.Boot.id(), execution_id)
      end)

    {:ok, 1} = Opus.Schedules.Scheduler.complete(schedule, occurrence, execution_id, output)
    occurrence.id
  end

  @doc """
  Stop this member's notes keeper from working, and hold the notes claim
  of `athanor_id` under this member's boot for `lease_ms`, as a member
  that took the work and then stopped would leave it.
  """
  @spec hold_notes!(String.t(), pos_integer()) :: map()
  def hold_notes!(athanor_id, lease_ms) do
    :ok = :sys.suspend(Aqua.ScheduleNotes, 30_000)
    {:ok, claim} = Arca.JobClaims.claim("schedule_notes", athanor_id, Prima.Boot.id(), lease_ms)
    claim
  end

  @doc "This member's notes keeper's drain of `athanor_id`, under this member's boot."
  @spec drain_notes(String.t()) :: term()
  def drain_notes(athanor_id), do: Aqua.ScheduleNotes.drain(athanor_id)

  @doc "The note `name` of `athanor_id` with its revision, as this member reads it, or `:none`."
  @spec note(String.t(), String.t()) :: map() | :none
  def note(athanor_id, name) do
    internal = Sanctum.Context.internal(user_id: "cluster", permissions: [:storage_read])

    with {:ok, ctx} <- Sanctum.Context.refocus(internal, athanor_id),
         {:ok, %{revision: revision, note: %{} = note}} <- Aqua.Notes.current(ctx, name) do
      Map.put(note, :revision, revision)
    else
      _ -> :none
    end
  end

  @doc """
  The outcome the notes keeper recorded for the occurrence
  `occurrence_id` of `athanor_id`, or `:none`.
  """
  @spec notes_outcome(String.t(), String.t()) :: String.t() | :none
  def notes_outcome(athanor_id, occurrence_id) do
    import Ecto.Query, only: [from: 2]

    Arca.Repo.one(
      from(c in Arca.Schemas.ConsumerReceipt,
        where: c.athanor_id == ^athanor_id and c.consumer == "schedule_notes",
        where: c.source_kind == "schedule_occurrence" and c.source_id == ^occurrence_id,
        select: c.outcome
      )
    ) || :none
  end

  @doc "Stop the application cleanly, releasing the slot and every claim."
  @spec stop!() :: :ok
  def stop! do
    Application.stop(:cyfr)
    :ok
  end

  @doc false
  # Kept so `Cyfr.Cluster.Cell.heal!/0` has one call for every cut a case
  # can make from outside a member. The database wire is the control
  # node's (`Cyfr.Cluster.Wire`), so there is nothing to put back here.
  @spec restore_store() :: :ok
  def restore_store, do: :ok
end
