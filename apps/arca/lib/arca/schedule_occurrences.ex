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
  (`:overlapping`). The execution's admission moves the occurrence to
  `started` inside its own transaction (`start!/3`, from
  `Arca.Execution.admit/2`), so a `claimed` occurrence is one nothing
  ever invoked, and the run's end closes it (`finish/3`).

  `claimed_by` names the BOOT that took the occurrence (`Cyfr.Boot.id/0`),
  not its node: an occurrence is held while its claimant is a live member
  of the cell, and a restarted node is a different boot whose work a
  successor may take. Whether the occurrence is due, and when it was
  claimed, are decided on DATABASE time (`Arca.ServerMetaStorage.now!/0`),
  so two members with skewed clocks agree which occurrence is ready.

  Every function that names an athanor takes the `Cyfr.Actor` first and
  matches it in its head; an actor whose athanor is nil or the empty
  string is refused before any query, as `{:error, :no_athanor}` from an
  entry point and as a raise from `start!/3`, which runs inside
  admission's transaction. `claim/3` takes the schedule row it advances
  and `recoverable/1` is the daemon's read across every athanor.
  """

  import Ecto.Query, only: [from: 2]

  alias Arca.CronSchedule
  alias Arca.Repo.Errors
  alias Arca.Schemas.ScheduleOccurrence

  @open ["claimed", "started"]
  @terminal ["completed", "failed", "uncertain"]

  @doc "The states of an occurrence still to be run or running."
  def open_states, do: @open

  @doc """
  Take the occurrence `schedule.next_run_at` names for the boot
  `claimant`, moving the cursor to `next_run`: `{:ok, occurrence}` when
  this call won it, `:held` when it was not due or another claimant
  advanced the cursor first, `:overlapping` when the schedule forbids
  concurrency and an occurrence of it is still open.

  Due is decided on the cell's clock, so a member whose own clock runs
  fast cannot fire a schedule before it is due for its peers.
  """
  @spec claim(CronSchedule.t(), String.t(), DateTime.t()) ::
          {:ok, ScheduleOccurrence.t()} | :held | :overlapping | {:error, :database_error}
  def claim(%CronSchedule{next_run_at: nil}, _claimant, _next_run), do: :held

  def claim(%CronSchedule{} = schedule, claimant, %DateTime{} = next_run)
      when is_binary(claimant) do
    Errors.with_db_rescue("ScheduleOccurrences.claim", fn ->
      now = Arca.ServerMetaStorage.now!()
      due_for = schedule.next_run_at

      Arca.Repo.transaction(fn ->
        {count, _} =
          from(s in CronSchedule,
            where: s.id == ^schedule.id and s.athanor_id == ^schedule.athanor_id,
            where: s.status == "active" and s.next_run_at == ^due_for and s.next_run_at <= ^now
          )
          |> Arca.Repo.update_all(set: [next_run_at: next_run])

        if count != 1, do: Arca.Repo.rollback(:held)

        # Due and won, but another occurrence of the schedule is still
        # open: the cursor stays where it was, and the occurrence waits.
        if schedule.concurrency == "forbid" and open?(schedule.athanor_id, schedule.id),
          do: Arca.Repo.rollback(:overlapping)

        %ScheduleOccurrence{}
        |> ScheduleOccurrence.changeset(%{
          id: Cyfr.UUID7.generate_id("occ"),
          athanor_id: schedule.athanor_id,
          schedule_id: schedule.id,
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
  end

  @doc """
  Move a `claimed` occurrence to `started` for `execution_id`, counting
  the attempt. Answers the rows moved: 0 when the occurrence was not
  claimed, so the admission it runs inside rolls back.
  """
  @spec start!(Cyfr.Actor.t(), String.t(), String.t()) :: non_neg_integer()
  # arca:db-raise-ok inside the admission transaction
  def start!(%Cyfr.Actor{athanor_id: athanor_id}, occurrence_id, execution_id)
      when is_binary(athanor_id) and athanor_id != "" do
    {count, _} =
      from(o in ScheduleOccurrence,
        where: o.athanor_id == ^athanor_id and o.id == ^occurrence_id and o.state == "claimed"
      )
      |> Arca.Repo.update_all(
        set: [state: "started", execution_id: execution_id],
        inc: [attempts: 1]
      )

    count
  end

  def start!(%Cyfr.Actor{}, _occurrence_id, _execution_id),
    do: Arca.QueryHelpers.no_athanor!("Arca.ScheduleOccurrences.start!/3")

  @doc "End an open occurrence as `completed`, `failed` or `uncertain`. Answers the rows moved."
  @spec finish(Cyfr.Actor.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, :no_athanor | :database_error}
  def finish(%Cyfr.Actor{athanor_id: athanor_id}, occurrence_id, state)
      when is_binary(athanor_id) and athanor_id != "" and state in @terminal do
    Errors.with_db_rescue("ScheduleOccurrences.finish", fn ->
      {count, _} =
        from(o in ScheduleOccurrence,
          where: o.athanor_id == ^athanor_id and o.id == ^occurrence_id and o.state in ^@open
        )
        |> Arca.Repo.update_all(set: [state: state, ended_at: DateTime.utc_now()])

      {:ok, count}
    end)
  end

  def finish(%Cyfr.Actor{}, _occurrence_id, _state), do: {:error, :no_athanor}

  @doc """
  End an occurrence whose runner died: one never invoked (`claimed`)
  failed, one started `uncertain` — the execution may have had its
  effect. Answers the state written, or nil when it was already closed.
  """
  @spec settle_dead(Cyfr.Actor.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, :no_athanor | :database_error}
  def settle_dead(%Cyfr.Actor{athanor_id: athanor_id} = actor, occurrence_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Errors.with_db_rescue("ScheduleOccurrences.settle_dead", fn ->
      case Arca.Repo.get_by(ScheduleOccurrence, athanor_id: athanor_id, id: occurrence_id) do
        %{state: "claimed"} ->
          {:ok, _} = finish(actor, occurrence_id, "failed")
          {:ok, "failed"}

        %{state: "started"} ->
          {:ok, _} = finish(actor, occurrence_id, "uncertain")
          {:ok, "uncertain"}

        _ ->
          {:ok, nil}
      end
    end)
  end

  def settle_dead(%Cyfr.Actor{}, _occurrence_id), do: {:error, :no_athanor}

  @doc "The occurrence, by id, within the actor's athanor."
  @spec get(Cyfr.Actor.t(), String.t()) ::
          {:ok, ScheduleOccurrence.t()} | {:error, :no_athanor | :not_found | :database_error}
  def get(%Cyfr.Actor{athanor_id: athanor_id}, id)
      when is_binary(athanor_id) and athanor_id != "" do
    Errors.with_db_rescue("ScheduleOccurrences.get", fn ->
      case Arca.Repo.get_by(ScheduleOccurrence, athanor_id: athanor_id, id: id) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
  end

  def get(%Cyfr.Actor{}, _id), do: {:error, :no_athanor}

  @doc "The schedule's occurrences within the actor's athanor, newest first."
  @spec list(Cyfr.Actor.t(), String.t(), keyword()) ::
          {:ok, [ScheduleOccurrence.t()]} | {:error, :no_athanor | :database_error}
  def list(actor, schedule_id, opts \\ [])

  def list(%Cyfr.Actor{athanor_id: athanor_id}, schedule_id, opts)
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
  end

  def list(%Cyfr.Actor{}, _schedule_id, _opts), do: {:error, :no_athanor}

  @doc """
  What a member may take over: the occurrences claimed and never invoked
  (their execution admission never happened, so they run once), and the
  started ones whose execution has ended or was swept while the occurrence
  stayed open (the run's outcome is unknown here: uncertain).

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
  """
  @spec recoverable(DateTime.t()) ::
          {:ok, %{never_invoked: [ScheduleOccurrence.t()], lapsed: [ScheduleOccurrence.t()]}}
          | {:error, :database_error}
  # arca:unscoped-ok the daemon's read spans every athanor; each row is
  # acted on under its own schedule's actor.
  def recoverable(%DateTime{} = claimed_before) do
    Errors.with_db_rescue("ScheduleOccurrences.recoverable", fn ->
      abandoned = abandoned(claimed_before)

      never_invoked = Arca.Repo.all(from(o in abandoned, where: o.state == "claimed"))

      lapsed =
        Arca.Repo.all(
          from(o in abandoned,
            left_join: e in Arca.Execution,
            on: e.id == o.execution_id and e.athanor_id == o.athanor_id,
            where: o.state == "started",
            where: is_nil(e.id) or e.status not in ["running", "paused"],
            select: o
          )
        )

      {:ok, %{never_invoked: never_invoked, lapsed: lapsed}}
    end)
  end

  @doc """
  Take an abandoned `claimed` occurrence from `previous` for `claimant`,
  so of two recoverers exactly one re-runs it.

  One statement, naming the occurrence, its state and the claimant it was
  read under: the loser matches nothing and is answered `:held`. The
  claim's clock moves with it, so the winner's re-run is not itself
  abandoned on the next pass.
  """
  @spec recover(Cyfr.Actor.t(), String.t(), String.t(), String.t()) ::
          :ok | :held | {:error, :no_athanor | :database_error}
  def recover(%Cyfr.Actor{athanor_id: athanor_id}, occurrence_id, previous, claimant)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(previous) and
             is_binary(claimant) do
    Errors.with_db_rescue("ScheduleOccurrences.recover", fn ->
      from(o in ScheduleOccurrence,
        where: o.athanor_id == ^athanor_id and o.id == ^occurrence_id,
        where: o.state == "claimed" and o.claimed_by == ^previous
      )
      |> Arca.Repo.update_all(set: [claimed_by: claimant, claimed_at: Arca.ServerMetaStorage.now!()])
      |> case do
        {1, _} -> :ok
        {0, _} -> :held
      end
    end)
  end

  def recover(%Cyfr.Actor{}, _occurrence_id, _previous, _claimant), do: {:error, :no_athanor}

  # Occurrences no live member is holding: the claimant's boot is not in
  # the cell's live roster, or the claim is older than the caller's window
  # whoever made it. `claimed_by` is never null for a row `claim/3` wrote;
  # one that is has no claimant to be alive.
  # arca:unscoped-ok the daemon's read spans every athanor; each row is
  # acted on under its own schedule's actor.
  defp abandoned(claimed_before) do
    live_owners =
      from(l in Arca.Schemas.CellLease,
        where: l.lease_until > ^Arca.ServerMetaStorage.now!(),
        select: l.owner
      )

    from(o in ScheduleOccurrence,
      where:
        o.claimed_at < ^claimed_before or is_nil(o.claimed_by) or
          o.claimed_by not in subquery(live_owners)
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
