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
  `claimant`, and move the cursor past it: `{:ok, occurrence}` when this
  call won it, `:skipped` when the due time was missed and the schedule
  declares `skip` (the cursor moved on, nothing fired), `:held` when it
  was not due or another claimant advanced the cursor first,
  `:overlapping` when the schedule forbids concurrency and an occurrence
  of it is still open.

  `schedule` is read for its `id`, its `athanor_id` and the
  `next_run_at` the caller saw, which is the cursor the write compares
  against; everything else the claim decides on, concurrency and the
  missed-run policy and episode included, is read from the row as it
  stands under its lock. Due is decided on the cell's clock, so a member
  whose own clock runs fast cannot fire a schedule before it is due for
  its peers.

  `cadence` carries what the claim cannot know of the schedule's
  expression: `next_after`, the first time the expression names strictly
  after a given instant (`{:ok, time}`, anything else when there is
  none), and `missed_bound_ms`, how late a due time may be claimed and
  still be an ordinary one: the larger of the scheduler's jitter and the
  slot lease, so neither a timer that fires a few seconds late nor a
  successor taking over a slot is downtime.

  A due time older than the bound at claim was missed. Under `skip` it
  does not fire: the cursor moves to the first time the bound does not
  call missed, and the claim answers `:skipped`. Under `catch_up` it
  opens an episode: `catch_up_until` is set to the horizon (every time at
  or before it was missed when the episode opened) and `catch_up_left`
  to the limit; each claim then fires the cursor's time, decrements
  `catch_up_left` and moves the cursor to the next time while some are
  left and the next is within the horizon. Otherwise the episode closes:
  the cursor moves to the first time the bound does not call missed, and
  both columns clear. The episode lives in those columns, so a restart or
  a takeover resumes it from the row. A due time within the bound fires
  under either policy, and the cursor moves to the next time after it.
  The cursor only ever moves forward from the time it fired, so the
  claim's own walk never names a time twice; a cursor some other write
  set to a time that already fired (a clock set back) is moved past it
  with nothing fired and answered `:held`, and the unique
  `(schedule_id, scheduled_for)` stands behind both.

  Every row, a schedule's and a feed's alike, is claimed only under the
  member's live slot: the row is locked and the slot checked before the
  cursor moves (`Arca.CronSchedule.slot_fence/0`), so a member that lost
  its slot, even while it waited on the lock, is answered
  `{:error, :not_owner}` with the cursor unmoved and no occurrence
  written.
  """
  @type cadence :: %{
          required(:next_after) => (DateTime.t() -> {:ok, DateTime.t()} | term()),
          required(:missed_bound_ms) => non_neg_integer()
        }

  @spec claim(map(), String.t(), cadence()) ::
          {:ok, map()}
          | :skipped
          | :held
          | :overlapping
          | {:error, :not_owner | :database_error}
  def claim(%{next_run_at: nil}, _claimant, _cadence), do: :held

  def claim(
        %{id: id, next_run_at: %DateTime{} = due_for} = schedule,
        claimant,
        %{next_after: next_after, missed_bound_ms: bound_ms}
      )
      when is_binary(id) and is_binary(claimant) and is_function(next_after, 1) and
             is_integer(bound_ms) and bound_ms >= 0 do
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

        row = due_row(athanor_id, id, due_for, now) || Arca.Repo.rollback(:held)
        horizon = DateTime.add(now, -bound_ms, :millisecond)

        case advance(row, due_for, horizon, next_after) do
          {:skip, cursor} ->
            move_cursor(athanor_id, id, cursor)
            :skipped

          {:fire, cursor} ->
            cond do
              # A cursor naming a time that already fired (a clock set
              # back behind a write that computed it) moves past it and
              # fires nothing: each time is fired once.
              fired?(athanor_id, id, due_for) ->
                move_cursor(athanor_id, id, cursor)
                :fired

              # Due and won, but another occurrence of the schedule is
              # still open: the cursor and the episode stay where they
              # were, and the occurrence waits.
              row.concurrency == "forbid" and open?(athanor_id, id) ->
                Arca.Repo.rollback(:overlapping)

              true ->
                move_cursor(athanor_id, id, cursor)
                insert_occurrence(athanor_id, id, due_for, claimant, now)
            end

          :none ->
            # The expression names no later time: nothing is claimed
            # rather than an occurrence nothing can advance past.
            Arca.Repo.rollback(:held)
        end
      end)
      |> case do
        {:ok, :skipped} -> :skipped
        {:ok, :fired} -> :held
        {:ok, row} -> {:ok, row}
        {:error, :held} -> :held
        {:error, :overlapping} -> :overlapping
        {:error, other} -> {:error, other}
      end
    end)
    |> Arca.Data.project()
  end

  # The locked row, read only while it is active, its cursor is the one
  # the caller saw and that cursor is due on the cell's clock.
  # arca:db-raise-ok inside the claim transaction
  defp due_row(athanor_id, id, due_for, now) do
    Arca.Repo.one(
      from(s in CronSchedule,
        where: s.id == ^id and s.athanor_id == ^athanor_id,
        where: s.status == "active" and s.next_run_at == ^due_for and s.next_run_at <= ^now,
        select:
          map(s, [
            :concurrency,
            :missed_runs,
            :catch_up_limit,
            :catch_up_until,
            :catch_up_left
          ])
      )
    )
  end

  # What the claim does with the due time and where the cursor goes, as
  # `{:fire | :skip, cursor}` with the episode columns the cursor carries,
  # or `:none` when the expression names no later time.
  defp advance(%{catch_up_left: left, catch_up_until: until}, due_for, horizon, next_after)
       when left > 0 do
    # An open episode: the cursor's time is one of its missed times.
    walk(due_for, left - 1, until, horizon, next_after)
  end

  defp advance(row, due_for, horizon, next_after) do
    cond do
      DateTime.compare(due_for, horizon) != :lt ->
        # Within the bound: an ordinary occurrence, whatever the policy.
        with {:ok, next} <- next_time(next_after, due_for), do: {:fire, episode(next, nil, 0)}

      row.missed_runs == "catch_up" ->
        walk(due_for, row.catch_up_limit - 1, horizon, horizon, next_after)

      true ->
        with {:ok, next} <- next_time(next_after, horizon), do: {:skip, episode(next, nil, 0)}
    end
  end

  # Fire `due_for` and keep the episode open on the next missed time while
  # some are left to fire and the next is within its horizon; otherwise
  # close it on the first time the bound does not call missed, and never
  # on one at or before `due_for`: a cell clock set back since the episode
  # opened puts the horizon behind the cursor, and the cursor still moves
  # forward.
  defp walk(due_for, left, until, horizon, next_after) do
    with {:ok, next} <- next_time(next_after, due_for) do
      if left > 0 and DateTime.compare(next, until) != :gt do
        {:fire, episode(next, until, left)}
      else
        with {:ok, resumed} <- next_time(next_after, horizon),
             do: {:fire, episode(max_time(resumed, next), nil, 0)}
      end
    end
  end

  defp episode(next_run_at, until, left),
    do: [next_run_at: next_run_at, catch_up_until: until, catch_up_left: left]

  # The expression's next time strictly after `instant`, never at or
  # before it, so the cursor only moves forward.
  defp next_time(next_after, instant) do
    case next_after.(instant) do
      {:ok, %DateTime{} = next} ->
        if DateTime.compare(next, instant) == :gt, do: {:ok, next}, else: :none

      _none ->
        :none
    end
  end

  defp max_time(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  # arca:db-raise-ok inside the claim transaction
  defp move_cursor(athanor_id, id, cursor) do
    from(s in CronSchedule, where: s.id == ^id and s.athanor_id == ^athanor_id)
    |> Arca.Repo.update_all(set: cursor)
    |> case do
      {1, _} -> :ok
      {_moved, _} -> Arca.Repo.rollback(:held)
    end
  end

  # The occurrence the claim won. A time already taken (the unique
  # `(schedule_id, scheduled_for)`) is another claim's, and this one is
  # held: the transaction rolls back with the cursor unmoved.
  # arca:db-raise-ok inside the claim transaction
  defp insert_occurrence(athanor_id, id, due_for, claimant, now) do
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

  `also:` (optional) is the higher owner's closure (`ARCHITECTURE.md`
  §4.4), run in the same transaction once the statement moved the row,
  and handed what the finish read there: the occurrence as it now stands
  (`note_revision_read` among its fields, the revision its run first read
  the schedule's note at), its schedule's `id`, `profile_id`, `metadata`
  and `updated_at`, and `consent_revision`, the revision of that
  profile's head consent (nil for none). It writes the outcome's record
  (`Arca.Outbox.put!/2`), so the occurrence ends and its record lands
  together or not at all. It answers `:ok`, or `{:error, reason}`, which
  rolls the finish back and is answered as it is; any other answer
  raises `ArgumentError`, which rolls it back too.

  Answers `{:ok, 1}`, or `{:error, :stale}` when nothing matched: the
  occurrence was ended already, or another claimant or execution holds
  it now, and nothing moved.
  """
  @spec finish(
          Prima.Actor.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          String.t(),
          keyword()
        ) ::
          {:ok, 1} | {:error, :stale | :no_athanor | :database_error | term()}
  def finish(actor, occurrence_id, claimed_by, execution_id, state, opts \\ [])

  def finish(
        %Prima.Actor{athanor_id: athanor_id},
        occurrence_id,
        claimed_by,
        execution_id,
        state,
        opts
      )
      when is_binary(athanor_id) and athanor_id != "" and state in @terminal and
             (is_binary(claimed_by) or is_nil(claimed_by)) and
             (is_binary(execution_id) or is_nil(execution_id)) and is_list(opts) do
    query =
      athanor_id
      |> open_held_by(occurrence_id, claimed_by)
      |> where_execution(execution_id)

    Errors.with_db_rescue("ScheduleOccurrences.finish", fn ->
      case Keyword.fetch(opts, :also) do
        :error ->
          ended(query, state)

        {:ok, also} when is_function(also, 1) ->
          ended_with(query, state, athanor_id, occurrence_id, also)
      end
    end)
  end

  def finish(%Prima.Actor{}, _occurrence_id, _claimed_by, _execution_id, _state, _opts),
    do: {:error, :no_athanor}

  # The finish and the owner's closure in one transaction: the closure
  # runs only once the row moved, and a refusal rolls the move back.
  # arca:db-raise-ok inside the caller's rescue
  defp ended_with(query, state, athanor_id, occurrence_id, also) do
    Arca.Repo.locking_transaction(fn ->
      with {:ok, 1} <- ended(query, state),
           :ok <- also_ran(also.(finished(athanor_id, occurrence_id))) do
        1
      else
        {:error, reason} -> Arca.Repo.rollback(reason)
      end
    end)
  end

  # What the finish hands its closure, read in its transaction.
  # arca:db-raise-ok inside the finish's transaction
  defp finished(athanor_id, occurrence_id) do
    occurrence =
      ScheduleOccurrence
      |> Arca.Repo.get_by!(athanor_id: athanor_id, id: occurrence_id)
      |> Arca.Data.project()

    schedule =
      Arca.Repo.one!(
        from(s in CronSchedule,
          where: s.athanor_id == ^athanor_id and s.id == ^occurrence.schedule_id,
          select: map(s, [:id, :profile_id, :metadata, :updated_at])
        )
      )

    %{
      occurrence: occurrence,
      schedule: schedule,
      consent_revision: consent_revision(athanor_id, schedule.profile_id)
    }
  end

  defp also_ran(:ok), do: :ok
  defp also_ran({:error, _reason} = refusal), do: refusal

  defp also_ran(other) do
    raise ArgumentError,
          "an also: closure answers :ok or {:error, reason}, got " <>
            Prima.LoggerContext.shape(other)
  end

  # The revision of the profile's head consent, or nil where it has none.
  # arca:db-raise-ok inside the caller's transaction
  defp consent_revision(athanor_id, profile_id) do
    Arca.Repo.one(
      from(p in Arca.Schemas.Profile,
        join: c in Arca.Schemas.Consent,
        on: c.id == p.head_consent_id and c.athanor_id == p.athanor_id,
        where: p.athanor_id == ^athanor_id and p.id == ^profile_id,
        select: c.revision
      )
    )
  end

  @doc """
  The started occurrence `execution_id` runs in the actor's athanor, while
  its run has read no note of its schedule yet: its `id`, its
  `schedule_id` and that schedule's stored `metadata`, which names the
  note. `:none` for an execution no such occurrence names.
  """
  @spec unread(Prima.Actor.t(), String.t()) ::
          {:ok, %{id: String.t(), schedule_id: String.t(), metadata: String.t() | nil}}
          | :none
          | {:error, :no_athanor | :database_error}
  def unread(%Prima.Actor{athanor_id: athanor_id}, execution_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(execution_id) do
    Errors.with_db_rescue("ScheduleOccurrences.unread", fn ->
      from(o in ScheduleOccurrence,
        join: s in CronSchedule,
        on: s.id == o.schedule_id and s.athanor_id == o.athanor_id,
        where: o.athanor_id == ^athanor_id and o.state == "started",
        where: o.execution_id == ^execution_id and is_nil(o.note_revision_read),
        select: %{id: o.id, schedule_id: o.schedule_id, metadata: s.metadata}
      )
      |> Arca.Repo.one()
      |> case do
        nil -> :none
        row -> {:ok, row}
      end
    end)
  end

  def unread(%Prima.Actor{}, _execution_id), do: {:error, :no_athanor}

  @doc """
  Record that the run `execution_id` of the occurrence first read its
  schedule's note at `revision` (0 for no note): one statement, matching
  the athanor, the occurrence and the execution, while the occurrence is
  `started` and has recorded no read. Answers `:ok` when it recorded,
  `:unchanged` when an earlier read already had, or the run no longer
  holds it started.
  """
  @spec note_read(Prima.Actor.t(), String.t(), String.t(), non_neg_integer()) ::
          :ok | :unchanged | {:error, :no_athanor | :database_error}
  def note_read(%Prima.Actor{athanor_id: athanor_id}, occurrence_id, execution_id, revision)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(occurrence_id) and
             is_binary(execution_id) and is_integer(revision) and revision >= 0 do
    Errors.with_db_rescue("ScheduleOccurrences.note_read", fn ->
      from(o in ScheduleOccurrence,
        where: o.athanor_id == ^athanor_id and o.id == ^occurrence_id,
        where: o.execution_id == ^execution_id and o.state == "started",
        where: is_nil(o.note_revision_read)
      )
      |> Arca.Repo.update_all(set: [note_revision_read: revision])
      |> case do
        {1, _} -> :ok
        {0, _} -> :unchanged
      end
    end)
  end

  def note_read(%Prima.Actor{}, _occurrence_id, _execution_id, _revision),
    do: {:error, :no_athanor}

  @doc """
  Inside the caller's locking transaction: whether the authority a
  schedule's outcome was recorded under still stands — the athanor is
  not archived, the schedule row exists, its bound profile `profile_id`
  is active, and that profile's head consent is at `consent_revision`
  (nil: it has none). The athanor, the schedule and the profile rows are
  read under a shared lock, in that order, the athanor before its rows,
  so an archive, a deletion, a revocation or a new head commits before
  this read or waits for the caller's commit.

  Answers `:ok` or `{:error, :authority_gone}`. Raises outside a
  transaction and on a store that cannot answer, so the caller's
  transaction rolls back.
  """
  @spec authority(Prima.Actor.t(), %{
          schedule_id: String.t(),
          profile_id: String.t(),
          consent_revision: non_neg_integer() | nil
        }) :: :ok | {:error, :authority_gone}
  # arca:db-raise-ok a step inside the caller's locking transaction; a raise rolls it back.
  def authority(%Prima.Actor{athanor_id: athanor_id}, %{
        schedule_id: schedule_id,
        profile_id: profile_id,
        consent_revision: revision
      })
      when is_binary(athanor_id) and athanor_id != "" and is_binary(schedule_id) and
             is_binary(profile_id) do
    unless Arca.Repo.in_transaction?() do
      raise ArgumentError, "Arca.ScheduleOccurrences.authority/2 runs inside a transaction"
    end

    athanor =
      from(a in Arca.Schemas.Athanor, where: a.id == ^athanor_id, select: a.status)
      |> Arca.QueryHelpers.for_share()
      |> Arca.Repo.one()

    schedule =
      from(s in CronSchedule,
        where: s.id == ^schedule_id and s.athanor_id == ^athanor_id,
        select: s.id
      )
      |> Arca.QueryHelpers.for_share()
      |> Arca.Repo.one()

    status =
      from(p in Arca.Schemas.Profile,
        where: p.athanor_id == ^athanor_id and p.id == ^profile_id,
        select: p.status
      )
      |> Arca.QueryHelpers.for_share()
      |> Arca.Repo.one()

    if (athanor not in [nil, "archived"] and schedule) && status == "active" &&
         consent_revision(athanor_id, profile_id) == revision,
       do: :ok,
       else: {:error, :authority_gone}
  end

  def authority(%Prima.Actor{}, %{}),
    do: Arca.QueryHelpers.no_athanor!("Arca.ScheduleOccurrences.authority/2")

  @doc """
  When the occurrence of schedule `schedule_id` that ran `execution_id`
  was due, in the actor's athanor, or `:none`: the order a schedule's
  outcomes land in.
  """
  @spec scheduled_for(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, DateTime.t()} | :none | {:error, :no_athanor | :database_error}
  def scheduled_for(%Prima.Actor{athanor_id: athanor_id}, schedule_id, execution_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(schedule_id) and
             is_binary(execution_id) do
    Errors.with_db_rescue("ScheduleOccurrences.scheduled_for", fn ->
      from(o in ScheduleOccurrence,
        where: o.athanor_id == ^athanor_id and o.schedule_id == ^schedule_id,
        where: o.execution_id == ^execution_id,
        select: o.scheduled_for,
        limit: 1
      )
      |> Arca.Repo.one()
      |> case do
        nil -> :none
        at -> {:ok, at}
      end
    end)
  end

  def scheduled_for(%Prima.Actor{}, _schedule_id, _execution_id), do: {:error, :no_athanor}

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
  defp fired?(athanor_id, schedule_id, scheduled_for) do
    Arca.Repo.exists?(
      from(o in ScheduleOccurrence,
        where: o.athanor_id == ^athanor_id and o.schedule_id == ^schedule_id,
        where: o.scheduled_for == ^scheduled_for
      )
    )
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
