# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ScheduleOccurrences do
  @moduledoc """
  Row-plane storage for a schedule's occurrences
  (`Arca.Schemas.ScheduleOccurrence`).

  An occurrence is taken once across the cell: `claim/3` advances the
  schedule's cursor and inserts the occurrence row in one transaction,
  so of two members firing the same due time one holds the row and the
  other is told `:held`. A schedule whose `concurrency` is `forbid` is
  not claimed while another of its occurrences is still open
  (`:overlapping`). Every occurrence, whatever its schedule's kind, is
  claimed only under the member's live slot, checked in the same
  transaction (`:not_owner` otherwise). The execution's admission moves
  the occurrence to `started` inside its own transaction (`start!/4`,
  from `Arca.Execution.admit/2`), and only for the boot that claims it:
  a member whose claim a recoverer took over (`recover/4`) starts
  nothing, so only the recoverer's re-run runs. A `claimed` occurrence is
  one nothing ever invoked, and the run's end closes it (`finish/5`).

  An occurrence is ended only by the claimant that holds it, for the
  execution it intends to end: `finish/5` and `settle_dead/4` are each a
  compare-and-set on the claimant and the execution, so a member whose
  occurrence a successor recovered and started ends nothing of the
  successor's (`:stale`).

  `claimed_by` names the BOOT that took the occurrence (`Prima.Boot.id/0`),
  not its node: an occurrence is held while its claimant is a live member
  of the cell, and a restarted node is a different boot whose work a
  successor may take. Whether the occurrence is due, and when it was
  claimed, are decided on DATABASE time (`Arca.ServerMetaStorage.now!/0`),
  so two members with skewed clocks agree which occurrence is ready.

  Every function that names an athanor takes the `Prima.Actor` first and
  matches it in its head; an actor whose athanor is nil or the empty
  string is refused before any query, as `{:error, :no_athanor}` from an
  entry point and as a raise from `start!/4`, which runs inside
  admission's transaction. `claim/3` takes the schedule it advances and
  `recoverable/1` is the daemon's read across every athanor. Every row a
  function here answers is a plain map (`Arca.Data`).
  """

  import Ecto.Query, only: [from: 2]

  alias Arca.Repo.Errors
  alias Arca.Schemas.{CronSchedule, ScheduleOccurrence}

  @open ["claimed", "started"]
  @terminal ["completed", "failed", "uncertain"]

  @doc "Every state an occurrence can be in: the open two and the terminal three."
  @spec states() :: [String.t()]
  def states, do: @open ++ @terminal

  @doc "The states of an occurrence still to be run or running."
  def open_states, do: @open

  @doc """
  Take the occurrence `schedule.next_run_at` names for the boot
  `claimant`, moving the cursor to `next_run`: `{:ok, occurrence}` when
  this call won it, `:held` when it was not due or another claimant
  advanced the cursor first, `:overlapping` when the schedule forbids
  concurrency and an occurrence of it is still open.

  `schedule` is read for its `id`, its `athanor_id` and the
  `next_run_at` the caller saw, which is the cursor the write compares
  against; everything else the claim decides on, concurrency included,
  is read from the row as it stands. Due is decided on the cell's clock,
  so a member whose own clock runs fast cannot fire a schedule before it
  is due for its peers.

  Every row, a schedule's and a feed's alike, is claimed only under the
  member's live slot: the row is locked and the slot checked before the
  cursor moves (`Arca.CronSchedule.slot_fence/0`), so a member that lost
  its slot, even while it waited on the lock, is answered
  `{:error, :not_owner}` with the cursor unmoved and no occurrence
  written.
  """
  @spec claim(map(), String.t(), DateTime.t()) ::
          {:ok, map()} | :held | :overlapping | {:error, :not_owner | :database_error}
  def claim(%{next_run_at: nil}, _claimant, _next_run), do: :held

  def claim(
        %{id: id, next_run_at: %DateTime{} = due_for} = schedule,
        claimant,
        %DateTime{} = next_run
      )
      when is_binary(id) and is_binary(claimant) do
    athanor_id = Map.fetch!(schedule, :athanor_id)

    Errors.with_db_rescue("ScheduleOccurrences.claim", fn ->
      now = Arca.ServerMetaStorage.now!()

      Arca.Repo.locking_transaction(fn ->
        # The row is locked before the cursor moves, and the slot is
        # checked once the lock is held, so a member whose slot was taken
        # over while it waited on the lock moves nothing.
        lock_schedule(athanor_id, id)

        with {:error, reason} <- Arca.CronSchedule.slot_fence(),
             do: Arca.Repo.rollback(reason)

        {count, _} =
          from(s in CronSchedule,
            where: s.id == ^id and s.athanor_id == ^athanor_id,
            where: s.status == "active" and s.next_run_at == ^due_for and s.next_run_at <= ^now
          )
          |> Arca.Repo.update_all(set: [next_run_at: next_run])

        if count != 1, do: Arca.Repo.rollback(:held)

        concurrency =
          Arca.Repo.one(from(s in CronSchedule, where: s.id == ^id, select: s.concurrency))

        # Due and won, but another occurrence of the schedule is still
        # open: the cursor stays where it was, and the occurrence waits.
        if concurrency == "forbid" and open?(athanor_id, id),
          do: Arca.Repo.rollback(:overlapping)

        %ScheduleOccurrence{}
        |> ScheduleOccurrence.changeset(%{
          id: Prima.UUID7.generate_id("occ"),
          athanor_id: athanor_id,
          schedule_id: id,
          scheduled_for: due_for,
          state: "claimed",
          claimed_by: claimant,
          claimed_at: now
        })
        |> Arca.Repo.insert()
        |> case do
          {:ok, row} -> row
          {:error, _changeset} -> Arca.Repo.rollback(:held)
        end
      end)
      |> case do
        {:ok, row} -> {:ok, row}
        {:error, :held} -> :held
        {:error, :overlapping} -> :overlapping
        {:error, other} -> {:error, other}
      end
    end)
    |> Arca.Data.project()
  end

  @doc """
  Move a `claimed` occurrence to `started` for `execution_id`, counting
  the attempt, only while `claimed_by` (the admitting boot) is its
  claimant: the state and the claimant are checked in the one guarded
  statement that moves it. Answers the rows moved: 0 when the occurrence
  is not claimed, or is claimed by another boot since a recoverer took
  it over, so the admission it runs inside rolls back.
  """
  @spec start!(Prima.Actor.t(), String.t(), String.t(), String.t()) :: non_neg_integer()
  # arca:db-raise-ok inside the admission transaction
  def start!(%Prima.Actor{athanor_id: athanor_id}, occurrence_id, claimed_by, execution_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(claimed_by) do
    {count, _} =
      from(o in ScheduleOccurrence,
        where: o.athanor_id == ^athanor_id and o.id == ^occurrence_id and o.state == "claimed",
        where: o.claimed_by == ^claimed_by
      )
      |> Arca.Repo.update_all(
        set: [state: "started", execution_id: execution_id],
        inc: [attempts: 1]
      )

    count
  end

  def start!(%Prima.Actor{}, _occurrence_id, _claimed_by, _execution_id),
    do: Arca.QueryHelpers.no_athanor!("Arca.ScheduleOccurrences.start!/4")

  @doc """
  End an open occurrence as `completed`, `failed` or `uncertain`, only
  while it is still the one `claimed_by` holds for `execution_id`: one
  statement, matching the occurrence's athanor and id, an open state, its
  claimant, and either that execution or, still `claimed`, none at all.
  `execution_id` nil matches only an occurrence never started.

  Answers `{:ok, 1}`, or `{:error, :stale}` when nothing matched: the
  occurrence was ended already, or another claimant or execution holds
  it now, and nothing moved.
  """
  @spec finish(Prima.Actor.t(), String.t(), String.t() | nil, String.t() | nil, String.t()) ::
          {:ok, 1} | {:error, :stale | :no_athanor | :database_error}
  def finish(
        %Prima.Actor{athanor_id: athanor_id},
        occurrence_id,
        claimed_by,
        execution_id,
        state
      )
      when is_binary(athanor_id) and athanor_id != "" and state in @terminal and
             (is_binary(claimed_by) or is_nil(claimed_by)) and
             (is_binary(execution_id) or is_nil(execution_id)) do
    Errors.with_db_rescue("ScheduleOccurrences.finish", fn ->
      athanor_id
      |> open_held_by(occurrence_id, claimed_by)
      |> where_execution(execution_id)
      |> ended(state)
    end)
  end

  def finish(%Prima.Actor{}, _occurrence_id, _claimed_by, _execution_id, _state),
    do: {:error, :no_athanor}

  @doc """
  End an occurrence whose runner died, only while `claimed_by` still
  holds it: one never invoked (`claimed`, with no execution) `failed`,
  one started under `execution_id` `uncertain`, since the execution may
  have had its effect. Each is a statement guarded on the occurrence's
  state, claimant and execution; nothing is read first.

  Answers the state written, or `{:error, :stale}` when neither matched:
  the occurrence was ended already, or another claimant or execution
  holds it now, and nothing moved.
  """
  @spec settle_dead(Prima.Actor.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | {:error, :stale | :no_athanor | :database_error}
  def settle_dead(%Prima.Actor{athanor_id: athanor_id}, occurrence_id, claimed_by, execution_id)
      when is_binary(athanor_id) and athanor_id != "" and
             (is_binary(claimed_by) or is_nil(claimed_by)) and
             (is_binary(execution_id) or is_nil(execution_id)) do
    Errors.with_db_rescue("ScheduleOccurrences.settle_dead", fn ->
      never_invoked =
        athanor_id
        |> open_held_by(occurrence_id, claimed_by)
        |> where_execution(nil)
        |> ended("failed")

      case {never_invoked, execution_id} do
        {{:ok, 1}, _execution_id} ->
          {:ok, "failed"}

        {{:error, :stale}, nil} ->
          {:error, :stale}

        {{:error, :stale}, execution_id} ->
          started_uncertain(athanor_id, occurrence_id, claimed_by, execution_id)
      end
    end)
  end

  def settle_dead(%Prima.Actor{}, _occurrence_id, _claimed_by, _execution_id),
    do: {:error, :no_athanor}

  # A started occurrence whose runner died, ended `uncertain` only while
  # it is still `claimed_by`'s under `execution_id`.
  # arca:db-raise-ok inside the caller's rescue
  defp started_uncertain(athanor_id, occurrence_id, claimed_by, execution_id) do
    from(o in open_held_by(athanor_id, occurrence_id, claimed_by),
      where: o.state == "started" and o.execution_id == ^execution_id
    )
    |> ended("uncertain")
    |> case do
      {:ok, 1} -> {:ok, "uncertain"}
      stale -> stale
    end
  end

  # The open occurrence, by athanor and id, while `claimed_by` holds it.
  # A claimant read as nil matches only a row that names none.
  defp open_held_by(athanor_id, occurrence_id, nil) do
    from(o in ScheduleOccurrence,
      where: o.athanor_id == ^athanor_id and o.id == ^occurrence_id and o.state in ^@open,
      where: is_nil(o.claimed_by)
    )
  end

  defp open_held_by(athanor_id, occurrence_id, claimed_by) do
    from(o in ScheduleOccurrence,
      where: o.athanor_id == ^athanor_id and o.id == ^occurrence_id and o.state in ^@open,
      where: o.claimed_by == ^claimed_by
    )
  end

  # The execution the caller intends to end, or the occurrence still
  # `claimed` with none; nil names only the second.
  defp where_execution(query, nil),
    do: from(o in query, where: o.state == "claimed" and is_nil(o.execution_id))

  defp where_execution(query, execution_id) do
    from(o in query,
      where:
        o.execution_id == ^execution_id or
          (o.state == "claimed" and is_nil(o.execution_id))
    )
  end

  # arca:db-raise-ok inside the caller's rescue
  defp ended(query, state) do
    case Arca.Repo.update_all(query, set: [state: state, ended_at: DateTime.utc_now()]) do
      {1, _} -> {:ok, 1}
      {0, _} -> {:error, :stale}
    end
  end

  @doc "The occurrence, by id, within the actor's athanor."
  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :no_athanor | :not_found | :database_error}
  def get(%Prima.Actor{athanor_id: athanor_id}, id)
      when is_binary(athanor_id) and athanor_id != "" do
    Errors.with_db_rescue("ScheduleOccurrences.get", fn ->
      case Arca.Repo.get_by(ScheduleOccurrence, athanor_id: athanor_id, id: id) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
    |> Arca.Data.project()
  end

  def get(%Prima.Actor{}, _id), do: {:error, :no_athanor}

  @doc "The schedule's occurrences within the actor's athanor, newest first."
  @spec list(Prima.Actor.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :no_athanor | :database_error}
  def list(actor, schedule_id, opts \\ [])

  def list(%Prima.Actor{athanor_id: athanor_id}, schedule_id, opts)
      when is_binary(athanor_id) and athanor_id != "" do
    Errors.with_db_rescue("ScheduleOccurrences.list", fn ->
      limit = Keyword.get(opts, :limit, 20)

      {:ok,
       Arca.Repo.all(
         from(o in ScheduleOccurrence,
           where: o.athanor_id == ^athanor_id and o.schedule_id == ^schedule_id,
           order_by: [desc: o.scheduled_for],
           limit: ^limit
         )
       )}
    end)
    |> Arca.Data.project()
  end

  def list(%Prima.Actor{}, _schedule_id, _opts), do: {:error, :no_athanor}

  @doc """
  What a member may take over: the occurrences claimed and never invoked
  (their execution admission never happened, so they run once), and the
  started ones whose execution has ended or was swept while the occurrence
  stayed open (the run's outcome is unknown here: uncertain).

  A started occurrence is answered by whose it is. One whose claimant is no
  live member has no task left to end it, and is `lapsed`, to be ended
  now. One whose claimant is a live member is `lapsed_live`: a run closes
  its execution before its task ends the occurrence, so the caller gives
  that task its grace, timed on the caller's own clock
  (`Opus.Schedules.Scheduler`), and no member's wall clock is read
  here. Whether an execution ended is its status alone, or its row being
  gone; when it ended is never compared.

  An occurrence is ABANDONED, and only then recoverable, when its
  `claimed_by` is no longer a live member's boot
  (`Arca.ControlPlane.live_member?/1`, read here as one statement against
  `cell_leases`) or it was claimed before `claimed_before` — the caller's
  clock less twice its own tick, so a claimant that is alive but has
  stopped making progress is still reached. A peer's occurrence claimed a
  millisecond ago belongs to that peer and is returned to nobody.

  The liveness test is a subquery over the cell's live slots rather than a
  round trip per row: every occurrence is judged against one instant of
  database time, so two members recovering at once see the same roster.
  All three reads seek the occurrences' `(state, claimed_at)` index, so a pass
  reads the open occurrences and never the kept history.
  """
  @spec recoverable(DateTime.t()) ::
          {:ok, %{never_invoked: [map()], lapsed: [map()], lapsed_live: [map()]}}
          | {:error, :database_error}
  # arca:unscoped-ok the daemon's read spans every athanor; each row is
  # acted on under its own schedule's actor.
  def recoverable(%DateTime{} = claimed_before) do
    Errors.with_db_rescue("ScheduleOccurrences.recoverable", fn ->
      live = live_owners()
      abandoned = abandoned(claimed_before, live)

      never_invoked = Arca.Repo.all(from(o in abandoned, where: o.state == "claimed"))

      ended =
        from(o in abandoned,
          left_join: e in Arca.Schemas.Execution,
          on: e.id == o.execution_id and e.athanor_id == o.athanor_id,
          where: o.state == "started",
          where: is_nil(e.id) or e.status not in ^Prima.ExecutionState.open_statuses(),
          select: o
        )

      lapsed =
        Arca.Repo.all(
          from(o in ended, where: is_nil(o.claimed_by) or o.claimed_by not in subquery(live))
        )

      lapsed_live =
        Arca.Repo.all(
          from(o in ended, where: not is_nil(o.claimed_by) and o.claimed_by in subquery(live))
        )

      {:ok, %{never_invoked: never_invoked, lapsed: lapsed, lapsed_live: lapsed_live}}
    end)
    |> Arca.Data.project()
  end

  @doc """
  Take an abandoned `claimed` occurrence from `previous` for `claimant`,
  so of two recoverers exactly one re-runs it.

  One statement, naming the occurrence, its state and the claimant it was
  read under: the loser matches nothing and is answered `:held`. The
  claim's clock moves with it, so the winner's re-run is not itself
  abandoned on the next pass.
  """
  @spec recover(Prima.Actor.t(), String.t(), String.t(), String.t()) ::
          :ok | :held | {:error, :no_athanor | :database_error}
  def recover(%Prima.Actor{athanor_id: athanor_id}, occurrence_id, previous, claimant)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(previous) and
             is_binary(claimant) do
    Errors.with_db_rescue("ScheduleOccurrences.recover", fn ->
      from(o in ScheduleOccurrence,
        where: o.athanor_id == ^athanor_id and o.id == ^occurrence_id,
        where: o.state == "claimed" and o.claimed_by == ^previous
      )
      |> Arca.Repo.update_all(
        set: [claimed_by: claimant, claimed_at: Arca.ServerMetaStorage.now!()]
      )
      |> case do
        {1, _} -> :ok
        {0, _} -> :held
      end
    end)
  end

  def recover(%Prima.Actor{}, _occurrence_id, _previous, _claimant), do: {:error, :no_athanor}

  # Occurrences no live member is holding: the claimant's boot is not in
  # the cell's live roster, or the claim is older than the caller's window
  # whoever made it. `claimed_by` is never null for a row `claim/3` wrote;
  # one that is has no claimant to be alive. The query is built here and
  # run by `recoverable/1`, which carries the tenancy marker for it.
  defp abandoned(claimed_before, live) do
    from(o in ScheduleOccurrence,
      where:
        o.claimed_at < ^claimed_before or is_nil(o.claimed_by) or
          o.claimed_by not in subquery(live)
    )
  end

  # The boots the cell's live slots name, at one instant of database time.
  defp live_owners do
    from(l in Arca.Schemas.CellLease,
      where: l.lease_until > ^Arca.ServerMetaStorage.now!(),
      select: l.owner
    )
  end

  # arca:db-raise-ok inside the claim transaction
  defp lock_schedule(athanor_id, schedule_id) do
    from(s in CronSchedule,
      where: s.id == ^schedule_id and s.athanor_id == ^athanor_id,
      select: s.id
    )
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.one()
  end

  # arca:db-raise-ok inside the claim transaction
  defp open?(athanor_id, schedule_id) do
    Arca.Repo.exists?(
      from(o in ScheduleOccurrence,
        where: o.athanor_id == ^athanor_id and o.schedule_id == ^schedule_id and o.state in ^@open
      )
    )
  end
end
