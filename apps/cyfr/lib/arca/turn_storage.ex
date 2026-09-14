# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.TurnStorage do
  @moduledoc """
  The durable turn: `turns`, `turn_steps`, `approvals`, the message rows
  a turn writes and the events it records, each transition one
  transaction.

  A turn is accepted with its message (`accept_message/3`), started once its
  root execution and pins exist (`start/3`), and every runner-owned write
  names the `fence` the runner holds: the transaction's first write is a
  conditional update of the turn row on that fence, which takes the row's
  lock, so a runner whose fence another process moved (`supersede/3`,
  `takeover/3`, `pause_recovered/3`) is refused `{:error, :superseded}`
  before it reads or writes anything else, and one that names no fence is
  refused `{:error, :fence_required}`. A host transition that takes a turn
  over compares the fence it read and mints the next one in one write.
  A step is proposed before its effect (`record_response/4`), flipped to
  `dispatched` in its own commit (`dispatch_step/3`), and closed with its
  result row, outcome and event together (`close_step/4`). Pause and
  resume flip the turn, its root attempt and its root execution in one
  transaction; `finish/4` is the one terminal write.

  Multi-row writes that append a message run under `with_seq_retry/1`:
  the `(thread_id, seq)` race surfaces as a changeset raise inside
  the transaction and the whole transaction is retried, since a retry
  inside an aborted Postgres transaction cannot land.

  """

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{Approval, Thread, Message, Turn, TurnStep}
  alias Sanctum.Context

  @statuses ["accepted", "running", "paused", "completed", "failed", "cancelled", "uncertain"]
  @open ["accepted", "running", "paused"]
  @terminal ["completed", "failed", "cancelled", "uncertain"]
  @step_kinds ["model", "tool", "ui", "approval", "clone", "launch"]
  @outcomes ["ok", "error", "denied", "skipped", "cancelled", "uncertain"]
  @decisions ["approved", "declined", "expired", "error"]
  @recovery_cap 3

  @doc "Every status a turn can carry."
  def statuses, do: @statuses

  @doc "The statuses of a turn that still owns work."
  def open_statuses, do: @open

  @doc "The statuses of a turn that is over."
  def terminal_statuses, do: @terminal

  @doc "How many automatic recoveries a turn gets before it is `uncertain`."
  def recovery_cap, do: @recovery_cap

  # ---------------------------------------------------------------------------
  # Acceptance
  # ---------------------------------------------------------------------------

  @doc """
  Accept a message, atomically with the work it opens. `attrs`:

  - `:message` — the row: `:author`, `:content`, `:payload`, optional
    `:id` (a caller-minted id, so attachments stored under it are found)
    and `:client_id` (the sender's retry identity).
  - `:turn` — `%{orchestrator, requested_by, model, options}` to open an
    `accepted` turn keyed by the message; `nil` for room content.
  - `:steer_turn_id` — attach the message to an open turn instead; a turn
    that has ended answers `{:error, :turn_over}`.

  Answers `{:ok, %{message: row, turn: row | nil}}`. A `client_id` this
  thread already accepted answers `{:error, :duplicate_client_id}`,
  a message `id` already taken `{:error, :message_id_reused}`
  (the caller reads the existing acceptance with `accepted/3`); a
  message that already opened a turn answers `{:error, :turn_exists}`.
  """
  @spec accept_message(Context.t(), String.t(), map()) ::
          {:ok, %{message: Message.t(), turn: Turn.t() | nil}} | {:error, term()}
  def accept_message(%Context{} = ctx, thread_id, attrs) when is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.accept_message", fn ->
      athanor_id = Context.athanor!(ctx)
      message = Map.fetch!(attrs, :message)

      with_seq_retry(fn ->
        Arca.Repo.transaction(fn ->
          thread = thread!(athanor_id, thread_id)

          row =
            Arca.ThreadStorage.insert_message!(
              ctx,
              thread,
              Map.put(message, :turn_id, Map.get(attrs, :steer_turn_id))
            )

          turn =
            case Map.get(attrs, :turn) do
              nil ->
                case Map.get(attrs, :steer_turn_id) do
                  nil -> nil
                  steer_id -> open_turn_of!(athanor_id, steer_id)
                end

              %{} = t ->
                open_turn!(athanor_id, thread, row, t)
            end

          %{message: %{row | turn_id: turn && turn.id}, turn: turn}
        end)
      end)
      |> case do
        {:error, %Ecto.Changeset{errors: errors} = changeset} ->
          cond do
            unique?(errors, :thread_id, "client_id") -> {:error, :duplicate_client_id}
            unique?(errors, :id, "messages") -> {:error, :message_id_reused}
            unique?(errors, :thread_id, "message_id") -> {:error, :turn_exists}
            true -> {:error, changeset}
          end

        other ->
          other
      end
    end)
  end

  @doc "The acceptance a sender's `client_id` already produced: its message and turn."
  @spec accepted(Context.t(), String.t(), String.t()) ::
          {:ok, %{message: Message.t(), turn: Turn.t() | nil}} | {:error, term()}
  def accepted(%Context{} = ctx, thread_id, client_id) do
    with {:ok, message} <-
           Arca.ThreadStorage.get_by_client_id(ctx, thread_id, client_id) do
      Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.accepted", fn ->
        athanor_id = Context.athanor!(ctx)

        turn =
          Arca.Repo.one(
            from(t in Turn,
              where: t.athanor_id == ^athanor_id and t.message_id == ^message.id
            )
          ) ||
            (message.turn_id &&
               Arca.Repo.one(
                 from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^message.turn_id)
               ))

        {:ok, %{message: message, turn: turn}}
      end)
    end
  end

  # arca:db-raise-ok inside the caller's transaction
  defp open_turn!(athanor_id, %Thread{} = thread, %Message{} = row, attrs) do
    now = DateTime.utc_now()

    turn =
      Arca.Repo.insert!(
        %Turn{}
        |> Ecto.Changeset.change(%{
          id: Cyfr.UUID7.generate_id("trn"),
          athanor_id: athanor_id,
          thread_id: thread.id,
          message_id: row.id,
          orchestrator: Map.get(attrs, :orchestrator),
          requested_by: Map.get(attrs, :requested_by),
          model: Map.get(attrs, :model),
          options: encode(Map.get(attrs, :options)),
          fence: new_fence(),
          runner_id: Cyfr.Boot.id(),
          status: "accepted",
          accepted_at: now
        })
        |> Ecto.Changeset.unique_constraint([:thread_id, :message_id])
      )

    # The initiating message belongs to its turn: attached, it is read by
    # this turn alone and by no other turn's projection.
    {1, _} =
      from(m in Message, where: m.athanor_id == ^athanor_id and m.id == ^row.id)
      |> Arca.Repo.update_all(set: [turn_id: turn.id])

    thread
    |> Thread.changeset(%{
      turn_seq: (thread.turn_seq || 0) + 1,
      orchestrator: Map.get(attrs, :orchestrator)
    })
    |> Arca.Repo.update!()

    turn
  end

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Start an accepted turn: `accepted → running` with its root execution,
  attempt, budget and pins (`:root_execution_id`, `:attempt`,
  `:budget_id`, `:profile_id`, `:consent_id`, `:agent_revision_digest`,
  `:agent_capability_digest`), and the consumption boundary set to the
  highest seq the turn may read now. Event `turn.started`.
  """
  @spec start(Context.t(), String.t(), map()) :: {:ok, Turn.t()} | {:error, term()}
  def start(%Context{} = ctx, turn_id, attrs) when is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.start", fn ->
      athanor_id = Context.athanor!(ctx)

      Arca.Repo.transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        window = boundary(athanor_id, turn)

        sets = [
          status: "running",
          root_execution_id: Map.get(attrs, :root_execution_id),
          attempt: Map.get(attrs, :attempt),
          budget_id: Map.get(attrs, :budget_id),
          profile_id: Map.get(attrs, :profile_id),
          consent_id: Map.get(attrs, :consent_id),
          agent_revision_digest: Map.get(attrs, :agent_revision_digest),
          agent_capability_digest: Map.get(attrs, :agent_capability_digest),
          runner_id: Cyfr.Boot.id(),
          window_upto_seq: window
        ]

        moved =
          from(t in Turn,
            where: t.athanor_id == ^athanor_id and t.id == ^turn_id and t.status == "accepted"
          )
          |> Arca.Repo.update_all(set: sets)
          |> elem(0)

        if moved != 1, do: Arca.Repo.rollback(:not_accepted)
        turn = turn!(athanor_id, turn_id)
        event!(athanor_id, turn, "turn.started", nil, %{})
        turn
      end)
    end)
  end

  @doc """
  Pause a running turn: the turn, its root attempt and its root execution
  leave `running` together. `attrs`: `:fence`, `:reason`
  (`"approval" | "launch"`), `:launch_step_id`. The running interval is
  added to `active_ms`. Event `turn.paused`.
  """
  @spec pause(Context.t(), String.t(), map()) :: {:ok, Turn.t()} | {:error, term()}
  def pause(%Context{} = ctx, turn_id, attrs \\ %{}) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.pause", fn ->
      athanor_id = Context.athanor!(ctx)

      Arca.Repo.transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        if turn.status != "running", do: Arca.Repo.rollback(:not_running)

        ran = Arca.ExecutionAttempts.pause!(athanor_id, turn.attempt) || 0
        execution_status!(athanor_id, turn.root_execution_id, "running", "paused")
        now = DateTime.utc_now()

        {1, _} =
          from(t in Turn,
            where: t.athanor_id == ^athanor_id and t.id == ^turn_id and t.status == "running"
          )
          |> Arca.Repo.update_all(
            set: [
              status: "paused",
              paused_at: now,
              paused_reason: Map.get(attrs, :reason, "approval"),
              launch_step_id: Map.get(attrs, :launch_step_id),
              active_ms: turn.active_ms + ran
            ]
          )

        turn = turn!(athanor_id, turn_id)
        event!(athanor_id, turn, "turn.paused", nil, %{"reason" => turn.paused_reason})
        turn
      end)
    end)
  end

  @doc """
  Resume a paused turn with a fresh lease: the turn, its root attempt and
  its root execution return to `running` together. Event `turn.resumed`.
  """
  @spec resume(Context.t(), String.t(), map()) :: {:ok, Turn.t()} | {:error, term()}
  def resume(%Context{} = ctx, turn_id, attrs \\ %{}) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.resume", fn ->
      athanor_id = Context.athanor!(ctx)

      Arca.Repo.transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        if turn.status != "paused", do: Arca.Repo.rollback(:not_paused)

        until = Map.get(attrs, :lease_until) || Arca.ExecutionAttempts.lease_until()

        if Arca.ExecutionAttempts.resume!(athanor_id, turn.attempt, until) != 1,
          do: Arca.Repo.rollback(:attempt_not_paused)

        execution_status!(athanor_id, turn.root_execution_id, "paused", "running")

        {1, _} =
          from(t in Turn,
            where: t.athanor_id == ^athanor_id and t.id == ^turn_id and t.status == "paused"
          )
          |> Arca.Repo.update_all(
            set: [status: "running", paused_at: nil, paused_reason: nil, launch_step_id: nil]
          )

        turn = turn!(athanor_id, turn_id)
        event!(athanor_id, turn, "turn.resumed", nil, %{})
        turn
      end)
    end)
  end

  @doc """
  Append one row the turn owns but no step produced — a compaction, an
  aborted mark, a system note — inside the turn's fence. `attrs`: the
  message's own fields plus `:fence`.

  These rows are part of what the next request reads, so a runner whose
  fence has moved must not be able to add one: a superseded loop appending
  a compaction would change the projection its successor is working from.
  """
  @spec append_turn_row(Context.t(), String.t(), map()) :: {:ok, Message.t()} | {:error, term()}
  def append_turn_row(%Context{} = ctx, turn_id, attrs) when is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.append_turn_row", fn ->
      athanor_id = Context.athanor!(ctx)

      Arca.Repo.transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        thread = thread!(athanor_id, turn.thread_id)

        Arca.ThreadStorage.insert_message!(
          ctx,
          thread,
          attrs |> Map.drop([:fence]) |> Map.put(:turn_id, turn.id)
        )
      end)
    end)
  end

  @doc """
  End a turn: the one terminal transaction. `status` is
  `completed | failed | cancelled | uncertain`; `attrs`: `:fence`,
  `:error`. The root attempt is closed with the matching outcome, the
  root execution leaves `running`/`paused`, the reservation is released
  and the open running interval is added to `active_ms`. A turn already
  over is answered `{:error, :already_finished}`; a turn with no root yet
  (still `accepted`) closes on its own. Event `turn.<status>`.
  """
  @spec finish(Context.t(), String.t(), String.t(), map()) :: {:ok, Turn.t()} | {:error, term()}
  def finish(%Context{} = ctx, turn_id, status, attrs \\ %{}) when status in @terminal do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.finish", fn ->
      athanor_id = Context.athanor!(ctx)

      Arca.Repo.transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        if turn.status in @terminal, do: Arca.Repo.rollback(:already_finished)

        ran =
          if turn.attempt do
            {attempt_state, outcome} = attempt_end(status)
            Arca.ExecutionAttempts.close!(athanor_id, turn.attempt, attempt_state, outcome) || 0
          else
            0
          end

        if turn.root_execution_id do
          execution_status!(
            athanor_id,
            turn.root_execution_id,
            ["running", "paused"],
            status_of(status),
            error: Map.get(attrs, :error)
          )

          Arca.BudgetReservations.close!(athanor_id, turn.root_execution_id)
        end

        {1, _} =
          from(t in Turn,
            where: t.athanor_id == ^athanor_id and t.id == ^turn_id and t.status in ^@open
          )
          |> Arca.Repo.update_all(
            set: [
              status: status,
              error: Map.get(attrs, :error),
              ended_at: DateTime.utc_now(),
              active_ms: turn.active_ms + ran,
              paused_at: nil,
              paused_reason: nil,
              launch_step_id: nil
            ]
          )

        turn = turn!(athanor_id, turn_id)
        event!(athanor_id, turn, "turn." <> status, nil, %{"error" => Map.get(attrs, :error)})
        turn
      end)
    end)
  end

  @doc """
  Take over a running turn another runner lost: the one place a
  successor attempt is opened. `attrs`: `:fence` (the one the caller read)
  and `:lease_until`. The turn's fence is compared and renewed first, then
  the predecessor is retired, the successor opened with the next fence and
  the pointer moved, `recovery_attempts` counted and the predecessor's
  unaccounted running interval added. Refused `{:error, :recovery_exhausted}` past
  the cap and `{:error, :not_open}` for a turn that is over.
  """
  @spec takeover(Context.t(), String.t(), map()) :: {:ok, Turn.t()} | {:error, term()}
  def takeover(%Context{} = ctx, turn_id, attrs \\ %{}) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.takeover", fn ->
      athanor_id = Context.athanor!(ctx)

      Arca.Repo.transaction(fn ->
        turn = take!(athanor_id, turn_id, attrs)
        if turn.status not in ["running", "paused"], do: Arca.Repo.rollback(:not_open)
        if turn.recovery_attempts >= @recovery_cap, do: Arca.Repo.rollback(:recovery_exhausted)
        if is_nil(turn.root_execution_id), do: Arca.Repo.rollback(:no_root)

        %{attempt: successor, ran_ms: ran} =
          Arca.ExecutionAttempts.takeover!(athanor_id, turn.root_execution_id,
            runner_id: Cyfr.Boot.id(),
            lease_until: Map.get(attrs, :lease_until) || Arca.ExecutionAttempts.lease_until()
          )

        execution_status!(
          athanor_id,
          turn.root_execution_id,
          ["running", "paused", "failed"],
          "running"
        )

        {1, _} =
          from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn_id)
          |> Arca.Repo.update_all(
            set: [
              status: "running",
              attempt: successor.attempt,
              runner_id: Cyfr.Boot.id(),
              recovery_attempts: turn.recovery_attempts + 1,
              active_ms: turn.active_ms + ran,
              paused_at: nil,
              paused_reason: nil,
              launch_step_id: nil
            ]
          )

        turn = turn!(athanor_id, turn_id)
        event!(athanor_id, turn, "turn.recovered", nil, %{"attempt" => successor.attempt})
        turn
      end)
    end)
  end

  @doc """
  Renew the turn's fence and mark every dispatched step cancel-requested,
  before its loop is stopped: a later write from the old fence and a
  later admission of those steps are refused. `attrs`: `:fence`, the one
  the caller read. Answers the turn with its new fence.
  """
  @spec supersede(Context.t(), String.t(), map()) :: {:ok, Turn.t()} | {:error, term()}
  def supersede(%Context{} = ctx, turn_id, attrs) when is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.supersede", fn ->
      athanor_id = Context.athanor!(ctx)

      Arca.Repo.transaction(fn ->
        _ = take!(athanor_id, turn_id, attrs)
        now = DateTime.utc_now()

        from(s in TurnStep,
          where: s.athanor_id == ^athanor_id and s.turn_id == ^turn_id,
          where: s.dispatch_state == "dispatched" and is_nil(s.cancel_requested_at)
        )
        |> Arca.Repo.update_all(set: [cancel_requested_at: now])

        turn!(athanor_id, turn_id)
      end)
    end)
  end

  @aborted_content "a call's outcome is unknown; tools may have partially executed"

  @doc """
  Stop a root turn on a call whose outcome is unknown, in one transaction:
  the step `:step_id` at `:generation` is marked `uncertain` with
  `:reason`; a running turn, its root attempt and its root execution
  leave `running` together (a turn paused around a launch keeps its
  released root); every other dispatched step is cancel-marked, so a
  sibling not yet admitted cannot admit; every proposed step is skipped;
  a `turn_aborted` row is appended whose payload `covers` names every
  step that was dispatched or uncertain at that moment; the turn is
  `paused` with reason `uncertain` and its boundary moved to that row.
  `:fence` is required. Answers the turn and the aborted row.
  """
  @spec pause_uncertain(Context.t(), String.t(), map()) ::
          {:ok, %{turn: Turn.t(), aborted: Message.t()}} | {:error, term()}
  def pause_uncertain(%Context{} = ctx, turn_id, attrs) when is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.pause_uncertain", fn ->
      athanor_id = Context.athanor!(ctx)

      with_seq_retry(fn ->
        Arca.Repo.transaction(fn ->
          turn = own!(athanor_id, turn_id, attrs)
          if turn.parent_turn_id, do: Arca.Repo.rollback(:clone)
          now = DateTime.utc_now()
          step = step!(athanor_id, Map.fetch!(attrs, :step_id))
          if step.turn_id != turn.id, do: Arca.Repo.rollback(:step_not_found)

          mark_uncertain!(
            athanor_id,
            turn,
            step,
            Map.fetch!(attrs, :generation),
            Map.get(attrs, :reason)
          )

          ran =
            case turn do
              %Turn{status: "running"} ->
                ran = Arca.ExecutionAttempts.pause!(athanor_id, turn.attempt) || 0
                execution_status!(athanor_id, turn.root_execution_id, "running", "paused")
                ran

              %Turn{status: "paused", paused_reason: "launch"} ->
                0

              _ ->
                Arca.Repo.rollback(:not_open)
            end

          content = Map.get(attrs, :content, @aborted_content)
          cancel_dispatched!(athanor_id, turn, step.id, now)
          _skipped = skip_proposed!(ctx, athanor_id, turn, content)
          aborted = aborted_row!(ctx, athanor_id, turn, content)

          {1, _} =
            from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn_id)
            |> Arca.Repo.update_all(
              set: [
                status: "paused",
                paused_at: now,
                paused_reason: "uncertain",
                launch_step_id: nil,
                window_upto_seq: aborted.seq,
                active_ms: turn.active_ms + ran
              ]
            )

          turn = turn!(athanor_id, turn_id)
          event!(athanor_id, turn, "turn.paused", nil, %{"reason" => "uncertain"})
          %{turn: turn, aborted: aborted}
        end)
      end)
    end)
  end

  @doc """
  A running turn a dead runner left holding an unacknowledged
  uncertainty is set down as paused `uncertain`, resumable: the
  predecessor attempt is retired with its running interval bounded by
  its lease (as a takeover does) and a successor is opened already
  paused, without counting a recovery; every dispatched step is marked
  `uncertain`, every proposed step skipped, and — when any of them is
  not yet covered — a covering `turn_aborted` row appended and the
  boundary moved to it. `attrs`: `:fence` (the one the caller read),
  `:content`. Answers the turn.
  """
  @spec pause_recovered(Context.t(), String.t(), map()) :: {:ok, Turn.t()} | {:error, term()}
  def pause_recovered(%Context{} = ctx, turn_id, attrs) when is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.pause_recovered", fn ->
      athanor_id = Context.athanor!(ctx)

      with_seq_retry(fn ->
        Arca.Repo.transaction(fn ->
          turn = take!(athanor_id, turn_id, attrs)
          if turn.status != "running", do: Arca.Repo.rollback(:not_running)
          if is_nil(turn.root_execution_id), do: Arca.Repo.rollback(:no_root)
          now = DateTime.utc_now()

          %{attempt: successor, ran_ms: ran} =
            Arca.ExecutionAttempts.takeover!(athanor_id, turn.root_execution_id,
              runner_id: Cyfr.Boot.id(),
              lease_until: Arca.ExecutionAttempts.lease_until()
            )

          _ = Arca.ExecutionAttempts.pause!(athanor_id, successor.attempt)

          execution_status!(
            athanor_id,
            turn.root_execution_id,
            ["running", "paused", "failed"],
            "paused"
          )

          content = Map.get(attrs, :content, @aborted_content)

          dispatched =
            Arca.Repo.all(
              from(s in TurnStep,
                where: s.athanor_id == ^athanor_id and s.turn_id == ^turn_id,
                where: s.dispatch_state == "dispatched"
              )
            )

          Enum.each(dispatched, &mark_uncertain!(athanor_id, turn, &1, &1.generation, content))
          _skipped = skip_proposed!(ctx, athanor_id, turn, content)

          window =
            if dispatched != [] or uncovered_uncertain(athanor_id, turn) != [],
              do: aborted_row!(ctx, athanor_id, turn, content).seq,
              else: turn.window_upto_seq

          {1, _} =
            from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn_id)
            |> Arca.Repo.update_all(
              set: [
                status: "paused",
                attempt: successor.attempt,
                runner_id: Cyfr.Boot.id(),
                paused_at: now,
                paused_reason: "uncertain",
                launch_step_id: nil,
                window_upto_seq: window,
                active_ms: turn.active_ms + ran
              ]
            )

          turn = turn!(athanor_id, turn_id)
          event!(athanor_id, turn, "turn.paused", nil, %{"reason" => "uncertain"})
          turn
        end)
      end)
    end)
  end

  @doc """
  Whether the turn holds an uncertainty nobody has acknowledged: an
  `uncertain` step no `turn_aborted` row covers, or a covering row with
  no later row from the turn's sender. A covered, acknowledged
  uncertainty is a restricted continuation, not an open episode.
  """
  @spec unacknowledged_episode?(Context.t(), String.t()) :: boolean() | {:error, term()}
  def unacknowledged_episode?(%Context{} = ctx, turn_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.unacknowledged_episode?", fn ->
      athanor_id = Context.athanor!(ctx)
      turn = turn!(athanor_id, turn_id)

      uncovered_uncertain(athanor_id, turn) != [] or
        Enum.any?(covering_rows(athanor_id, turn), fn row ->
          not Arca.Repo.exists?(
            from(m in Message,
              where: m.athanor_id == ^athanor_id and m.turn_id == ^turn.id,
              where: m.author == ^turn.requested_by and m.seq > ^row.seq
            )
          )
        end)
    end)
  end

  @doc "Whether any step of the turn is `uncertain`: the continuation runs replay-safe reads only."
  @spec restricted?(Context.t(), String.t()) :: boolean() | {:error, term()}
  def restricted?(%Context{} = ctx, turn_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.restricted?", fn ->
      athanor_id = Context.athanor!(ctx)

      Arca.Repo.exists?(
        from(s in TurnStep,
          where: s.athanor_id == ^athanor_id and s.turn_id == ^turn_id,
          where: s.dispatch_state == "uncertain"
        )
      )
    end)
  end

  # arca:db-raise-ok inside the caller's transaction
  defp cancel_dispatched!(athanor_id, %Turn{} = turn, except_step_id, now) do
    from(s in TurnStep,
      where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id,
      where: s.dispatch_state == "dispatched" and is_nil(s.cancel_requested_at),
      where: s.id != ^except_step_id
    )
    |> Arca.Repo.update_all(set: [cancel_requested_at: now])
  end

  # The covering aborted row: every step dispatched or uncertain now.
  # arca:db-raise-ok inside the caller's transaction
  defp aborted_row!(ctx, athanor_id, %Turn{} = turn, content) do
    covers =
      Arca.Repo.all(
        from(s in TurnStep,
          where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id,
          where: s.dispatch_state in ["dispatched", "uncertain"],
          order_by: [asc: s.seq],
          select: %{"step_id" => s.id, "generation" => s.generation}
        )
      )

    thread = thread!(athanor_id, turn.thread_id)

    Arca.ThreadStorage.insert_message!(ctx, thread, %{
      author: Message.system_author(),
      kind: "turn_aborted",
      content: content,
      payload: %{"covers" => covers},
      turn_id: turn.id,
      execution_id: turn.root_execution_id
    })
  end

  defp covering_rows(athanor_id, %Turn{} = turn) do
    from(m in Message,
      where: m.athanor_id == ^athanor_id and m.turn_id == ^turn.id,
      where: m.kind == "turn_aborted",
      order_by: [asc: m.seq]
    )
    |> Arca.Repo.all()
    |> Enum.map(fn row ->
      covers =
        row
        |> Arca.ThreadStorage.payload()
        |> Map.get("covers", [])
        |> Enum.map(&{&1["step_id"], &1["generation"]})

      %{seq: row.seq, covers: covers}
    end)
    |> Enum.reject(&(&1.covers == []))
  end

  defp uncovered_uncertain(athanor_id, %Turn{} = turn) do
    covered =
      athanor_id
      |> covering_rows(turn)
      |> Enum.flat_map(& &1.covers)
      |> MapSet.new()

    from(s in TurnStep,
      where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id,
      where: s.dispatch_state == "uncertain",
      select: {s.id, s.generation}
    )
    |> Arca.Repo.all()
    |> Enum.reject(&MapSet.member?(covered, &1))
  end

  # ---------------------------------------------------------------------------
  # Steps
  # ---------------------------------------------------------------------------

  @doc """
  Record one step of a turn at the next `seq`. `attrs`: `:kind`,
  `:tool`, `:action`, `:idempotency_key`, `:authority_digest`,
  `:request_digest`, `:proposal_digest`, `:recovery`, `:excluded` (a
  list), `:message_id`, `:child_execution_id`, `:dispatch_state`
  (default `proposed`), `:fence`.
  """
  @spec put_step(Context.t(), String.t(), map()) :: {:ok, TurnStep.t()} | {:error, term()}
  def put_step(%Context{} = ctx, turn_id, attrs) when is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.put_step", fn ->
      athanor_id = Context.athanor!(ctx)

      Arca.Repo.transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        insert_step!(athanor_id, turn, attrs)
      end)
    end)
  end

  @doc """
  Persist a model response before any of its calls run: the model step
  closes with its usage, the reply and every tool call become message
  rows, every call becomes a `proposed` step, and one event records it.
  `response`: `:text`, `:usage`, `:stop_reason`, `:tool_calls` — each
  `%{tool_call_id, name, tool, action, arguments, provider_data, kind,
  recovery, child_execution_id}`; `:fence`. Answers
  `{:ok, %{text: row | nil, calls: [%{message: row, step: step}]}}`.
  """
  @spec record_response(Context.t(), String.t(), String.t(), map()) ::
          {:ok, %{text: Message.t() | nil, calls: [map()]}} | {:error, term()}
  def record_response(%Context{} = ctx, turn_id, model_step_id, response)
      when is_map(response) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.record_response", fn ->
      athanor_id = Context.athanor!(ctx)

      with_seq_retry(fn ->
        Arca.Repo.transaction(fn ->
          turn = own!(athanor_id, turn_id, response)
          thread = thread!(athanor_id, turn.thread_id)
          now = DateTime.utc_now()

          text =
            case Map.get(response, :text) do
              nil ->
                nil

              "" ->
                nil

              content ->
                Arca.ThreadStorage.insert_message!(ctx, thread, %{
                  author: Message.agent_author(),
                  kind: "text",
                  content: content,
                  payload: %{"step_id" => model_step_id},
                  turn_id: turn_id,
                  execution_id: turn.root_execution_id
                })
            end

          {1, _} =
            from(s in TurnStep,
              where: s.athanor_id == ^athanor_id and s.id == ^model_step_id,
              where: s.turn_id == ^turn_id and s.dispatch_state in ["proposed", "dispatched"]
            )
            |> Arca.Repo.update_all(
              set: [
                dispatch_state: "closed",
                outcome: "ok",
                usage: encode(Map.get(response, :usage)),
                result_message_id: text && text.id,
                ended_at: now
              ]
            )

          calls =
            response
            |> Map.get(:tool_calls, [])
            |> Enum.map(fn call ->
              row =
                Arca.ThreadStorage.insert_message!(ctx, thread, %{
                  author: Message.agent_author(),
                  kind: "tool_call",
                  content: Map.get(call, :name, ""),
                  payload:
                    %{
                      "tool_call_id" => Map.get(call, :tool_call_id),
                      "name" => Map.get(call, :name),
                      "tool" => Map.get(call, :tool),
                      "action" => Map.get(call, :action),
                      "arguments" => Map.get(call, :arguments),
                      "provider_data" => Map.get(call, :provider_data),
                      "kind" => Map.get(call, :kind),
                      "step_id" => model_step_id
                    }
                    |> reject_nil(),
                  turn_id: turn_id,
                  execution_id: turn.root_execution_id
                })

              step =
                insert_step!(athanor_id, turn, %{
                  kind: Map.get(call, :step_kind, "tool"),
                  tool: Map.get(call, :tool),
                  action: Map.get(call, :action),
                  idempotency_key: Map.get(call, :idempotency_key),
                  proposal_digest: Map.get(call, :proposal_digest),
                  recovery: Map.get(call, :recovery),
                  message_id: row.id,
                  child_execution_id: Map.get(call, :child_execution_id),
                  authority_digest: Map.get(call, :authority_digest)
                })

              %{message: row, step: step}
            end)

          event!(athanor_id, turn, "model.completed", model_step_id, %{
            "usage" => Map.get(response, :usage),
            "stop_reason" => Map.get(response, :stop_reason),
            "calls" => length(calls)
          })

          %{text: text, calls: calls}
        end)
      end)
    end)
  end

  @doc """
  Flip a proposed step to `dispatched` in its own commit. Answers the
  step, or `{:error, :not_proposed}` when it was not proposed (dispatched
  already, closed, or cancel-requested).
  """
  @spec dispatch_step(Context.t(), String.t(), map()) :: {:ok, TurnStep.t()} | {:error, term()}
  def dispatch_step(%Context{} = ctx, step_id, attrs \\ %{}) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.dispatch_step", fn ->
      athanor_id = Context.athanor!(ctx)

      Arca.Repo.transaction(fn ->
        _ = own_step!(athanor_id, step_id, attrs)

        {count, _} =
          from(s in TurnStep,
            where: s.athanor_id == ^athanor_id and s.id == ^step_id,
            where: s.dispatch_state == "proposed" and is_nil(s.cancel_requested_at)
          )
          |> Arca.Repo.update_all(
            set: [dispatch_state: "dispatched", started_at: DateTime.utc_now()]
          )

        if count != 1, do: Arca.Repo.rollback(:not_proposed)
        step!(athanor_id, step_id)
      end)
    end)
  end

  @doc """
  Close a step with its result: the `tool_result` row, the step's
  `outcome`, `execution_id` and error, and the `step.closed` event, in
  one transaction. `attrs`: `:result` (`%{content, payload}` for the
  row; omitted for a step that produced none), `:execution_id`, `:error`,
  `:fence`. A step closes from `dispatched`, or from `proposed` for
  `denied` and `skipped`.
  """
  @spec close_step(Context.t(), String.t(), String.t(), map()) ::
          {:ok, %{step: TurnStep.t(), result: Message.t() | nil}} | {:error, term()}
  def close_step(%Context{} = ctx, step_id, outcome, attrs \\ %{}) when outcome in @outcomes do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.close_step", fn ->
      athanor_id = Context.athanor!(ctx)

      with_seq_retry(fn ->
        Arca.Repo.transaction(fn ->
          turn = own_step!(athanor_id, step_id, attrs)
          step = step!(athanor_id, step_id)
          close_step!(ctx, athanor_id, turn, step, outcome, attrs)
        end)
      end)
    end)
  end

  @doc """
  Mark a dispatched step as `uncertain`: its effect may have happened and
  its result is not known. `attrs`: `:fence` (the turn's, required) and
  `:generation` (the step's, required), so a superseded runner or a stale
  generation marks nothing. Answers `{:error, :not_dispatched}` for a
  step in any other state. Event `step.uncertain`.
  """
  @spec mark_step_uncertain(Context.t(), String.t(), String.t() | nil, map()) ::
          {:ok, TurnStep.t()} | {:error, term()}
  def mark_step_uncertain(%Context{} = ctx, step_id, reason, attrs) when is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.mark_step_uncertain", fn ->
      athanor_id = Context.athanor!(ctx)

      Arca.Repo.transaction(fn ->
        turn = own_step!(athanor_id, step_id, attrs)
        step = step!(athanor_id, step_id)
        mark_uncertain!(athanor_id, turn, step, Map.fetch!(attrs, :generation), reason)
        step!(athanor_id, step_id)
      end)
    end)
  end

  # arca:db-raise-ok inside the caller's transaction
  defp mark_uncertain!(athanor_id, %Turn{} = turn, %TurnStep{} = step, generation, reason) do
    {count, _} =
      from(s in TurnStep,
        where: s.athanor_id == ^athanor_id and s.id == ^step.id,
        where: s.dispatch_state == "dispatched" and s.generation == ^generation
      )
      |> Arca.Repo.update_all(
        set: [
          dispatch_state: "uncertain",
          outcome: "uncertain",
          error: reason,
          ended_at: DateTime.utc_now()
        ]
      )

    if count != 1, do: Arca.Repo.rollback(:not_dispatched)
    event!(athanor_id, turn, "step.uncertain", step.id, %{"reason" => reason})
    :ok
  end

  @doc """
  Close every unstarted step of a turn as `skipped` with a synthetic
  result, and invalidate their pending approvals. Answers the steps
  skipped.
  """
  @spec skip_steps(Context.t(), String.t(), String.t(), map()) ::
          {:ok, [TurnStep.t()]} | {:error, term()}
  def skip_steps(%Context{} = ctx, turn_id, reason, attrs \\ %{}) when is_binary(reason) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.skip_steps", fn ->
      athanor_id = Context.athanor!(ctx)

      with_seq_retry(fn ->
        Arca.Repo.transaction(fn ->
          turn = own!(athanor_id, turn_id, attrs)
          skip_proposed!(ctx, athanor_id, turn, reason)
        end)
      end)
    end)
  end

  # arca:db-raise-ok inside the caller's transaction
  defp skip_proposed!(ctx, athanor_id, %Turn{} = turn, reason) do
    steps =
      Arca.Repo.all(
        from(s in TurnStep,
          where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id,
          where: s.dispatch_state == "proposed",
          order_by: [asc: s.seq]
        )
      )

    Enum.map(steps, fn step ->
      if step.approval_id do
        from(a in Approval,
          where: a.athanor_id == ^athanor_id and a.id == ^step.approval_id,
          where: a.status == "pending"
        )
        |> Arca.Repo.update_all(set: [status: "invalidated", decided_at: DateTime.utc_now()])

        from(m in Message,
          where: m.athanor_id == ^athanor_id and m.approval_id == ^step.approval_id,
          where: m.status == "pending"
        )
        |> Arca.Repo.update_all(set: [status: "invalidated"])
      end

      %{step: closed} =
        close_step!(ctx, athanor_id, turn, step, "skipped", %{
          result: %{content: reason, payload: %{"skipped" => true}}
        })

      closed
    end)
  end

  @doc """
  Rewrite a step's bookkeeping (`:excluded`, `:request_digest`, `:error`,
  `:authority_digest`) under `:fence`. Answers the rows written.
  """
  @spec update_step(Context.t(), String.t(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def update_step(%Context{} = ctx, step_id, attrs) when is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.update_step", fn ->
      athanor_id = Context.athanor!(ctx)

      sets =
        attrs
        |> Map.take([:excluded, :request_digest, :error, :authority_digest])
        |> Enum.map(fn
          {:excluded, list} -> {:excluded, encode(list)}
          other -> other
        end)

      Arca.Repo.transaction(fn ->
        _ = own_step!(athanor_id, step_id, attrs)

        from(s in TurnStep, where: s.athanor_id == ^athanor_id and s.id == ^step_id)
        |> Arca.Repo.update_all(set: sets)
        |> elem(0)
      end)
    end)
  end

  @doc """
  The step barrier, run inside admission's transaction: bind the child
  execution to its step while the step is dispatched, on this generation,
  not cancel-requested, and the child id is the one the step pre-minted.
  Answers the rows bound — 0 when admission must abort.
  """
  @spec bind_child!(String.t(), String.t(), non_neg_integer(), String.t()) :: non_neg_integer()
  # arca:db-raise-ok inside the caller's transaction
  def bind_child!(athanor_id, step_id, generation, execution_id) when is_binary(athanor_id) do
    {count, _} =
      from(s in TurnStep,
        where: s.athanor_id == ^athanor_id and s.id == ^step_id,
        where: s.generation == ^generation and s.dispatch_state == "dispatched",
        where: is_nil(s.cancel_requested_at) and s.child_execution_id == ^execution_id
      )
      |> Arca.Repo.update_all(set: [execution_id: execution_id])

    count
  end

  @doc """
  Open the next generation of a step for a replay-safe re-dispatch: the
  old generation is cancel-marked so its late admission is refused, and
  the step returns to `proposed` with `generation + 1` and a fresh child
  execution id. `attrs`: `:child_execution_id`, `:fence`. Answers the step.
  """
  @spec next_generation(Context.t(), String.t(), map()) :: {:ok, TurnStep.t()} | {:error, term()}
  def next_generation(%Context{} = ctx, step_id, attrs) when is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.next_generation", fn ->
      athanor_id = Context.athanor!(ctx)

      Arca.Repo.transaction(fn ->
        _ = own_step!(athanor_id, step_id, attrs)
        step = step!(athanor_id, step_id)

        {1, _} =
          from(s in TurnStep, where: s.athanor_id == ^athanor_id and s.id == ^step_id)
          |> Arca.Repo.update_all(
            set: [
              generation: step.generation + 1,
              dispatch_state: "proposed",
              cancel_requested_at: nil,
              child_execution_id: Map.fetch!(attrs, :child_execution_id),
              execution_id: nil,
              started_at: nil
            ]
          )

        step!(athanor_id, step_id)
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # Approvals
  # ---------------------------------------------------------------------------

  @doc """
  Open an approval for a proposed step: the `approvals` row, the card
  message row that references it, and the step's `approval_id`, in one
  transaction. `attrs`: `:proposal_digest`, `:expires_at`, `:scope`,
  `:card` (`%{content, payload}` — the payload the console card reads),
  `:fence`. Answers `{:ok, %{approval: row, card: row}}`.
  """
  @spec open_approval(Context.t(), String.t(), map()) ::
          {:ok, %{approval: Approval.t(), card: Message.t()}} | {:error, term()}
  def open_approval(%Context{} = ctx, step_id, attrs) when is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.open_approval", fn ->
      athanor_id = Context.athanor!(ctx)

      with_seq_retry(fn ->
        Arca.Repo.transaction(fn ->
          turn = own_step!(athanor_id, step_id, attrs)
          step = step!(athanor_id, step_id)
          thread = thread!(athanor_id, turn.thread_id)
          card = Map.get(attrs, :card, %{})
          approval_id = Map.get(attrs, :id) || Cyfr.UUID7.generate_id("apr")
          now = DateTime.utc_now()

          card_row =
            Arca.ThreadStorage.insert_message!(ctx, thread, %{
              id: Map.get(card, :id),
              author: Message.agent_author(),
              kind: "approval",
              content: Map.get(card, :content, ""),
              payload: Map.get(card, :payload),
              status: "pending",
              turn_id: turn.id,
              approval_id: approval_id,
              execution_id: turn.root_execution_id
            })

          approval =
            Arca.Repo.insert!(%Approval{
              id: approval_id,
              athanor_id: athanor_id,
              turn_id: turn.id,
              step_id: step.id,
              message_id: card_row.id,
              thread_id: turn.thread_id,
              status: "pending",
              scope: Map.get(attrs, :scope),
              proposal_digest: Map.get(attrs, :proposal_digest, ""),
              expires_at: Map.get(attrs, :expires_at),
              inserted_at: now
            })

          {1, _} =
            from(s in TurnStep, where: s.athanor_id == ^athanor_id and s.id == ^step_id)
            |> Arca.Repo.update_all(set: [approval_id: approval_id])

          event!(athanor_id, turn, "approval.opened", step_id, %{"approval_id" => approval_id})
          %{approval: approval, card: card_row}
        end)
      end)
    end)
  end

  @doc """
  Resolve a pending approval in one transaction. `decision` is
  `approved | declined | expired | error`; `attrs`: `:decided_by`,
  `:scope`, `:resolution_kind` (`continue | launch | denied | expired`),
  `:resolution` (a map, stored as JSON), `:denied_result`
  (`%{content, payload}` — the `tool_result` row a declined, expired or
  errored step leaves), `:grants` (rows for `Arca.ToolGrantStorage.put/1`,
  written here so the standing answer lands with the decision), `:fence`.
  An approved step returns to `proposed` (its kind becomes `launch` for a
  launch); any other decision closes it `denied`. Answers
  `{:ok, %{approval, step, card}}`; a decision already made answers
  `{:error, {:already_resolved, approval}}`.
  """
  @spec resolve_approval(Context.t(), String.t(), String.t(), map()) ::
          {:ok, %{approval: Approval.t(), step: TurnStep.t(), card: Message.t()}}
          | {:error, term()}
  def resolve_approval(%Context{} = ctx, approval_id, decision, attrs)
      when decision in @decisions and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.resolve_approval", fn ->
      athanor_id = Context.athanor!(ctx)

      with_seq_retry(fn ->
        Arca.Repo.transaction(fn ->
          approval = approval!(athanor_id, approval_id)
          turn = own!(athanor_id, approval.turn_id, attrs)
          approval = approval!(athanor_id, approval_id)
          if approval.status != "pending", do: Arca.Repo.rollback({:already_resolved, approval})
          step = step!(athanor_id, approval.step_id)
          now = DateTime.utc_now()
          resolution_kind = Map.get(attrs, :resolution_kind)

          {1, _} =
            from(a in Approval,
              where: a.athanor_id == ^athanor_id and a.id == ^approval_id,
              where: a.status == "pending"
            )
            |> Arca.Repo.update_all(
              set: [
                status: decision,
                scope: Map.get(attrs, :scope, approval.scope),
                decided_by: Map.get(attrs, :decided_by),
                decided_at: now,
                resolution_kind: resolution_kind,
                resolution: encode(Map.get(attrs, :resolution))
              ]
            )

          from(m in Message,
            where: m.athanor_id == ^athanor_id and m.id == ^approval.message_id
          )
          |> Arca.Repo.update_all(
            set: [
              status: decision,
              resolved_by: Map.get(attrs, :decided_by),
              resolved_at: now,
              resolution: encode(Map.get(attrs, :resolution))
            ]
          )

          if decision == "approved" do
            kind = if resolution_kind == "launch", do: "launch", else: step.kind

            {1, _} =
              from(s in TurnStep, where: s.athanor_id == ^athanor_id and s.id == ^step.id)
              |> Arca.Repo.update_all(set: [dispatch_state: "proposed", kind: kind])
          else
            close_step!(ctx, athanor_id, turn, step, "denied", %{
              result: Map.get(attrs, :denied_result),
              error: Map.get(attrs, :reason)
            })
          end

          Enum.each(Map.get(attrs, :grants, []), fn grant ->
            case Arca.ToolGrantStorage.put(grant) do
              {:ok, _} -> :ok
              {:error, reason} -> Arca.Repo.rollback({:grant_failed, reason})
            end
          end)

          event!(athanor_id, turn, "approval.resolved", step.id, %{
            "approval_id" => approval_id,
            "decision" => decision,
            "resolution_kind" => resolution_kind
          })

          %{
            approval: approval!(athanor_id, approval_id),
            step: step!(athanor_id, step.id),
            card: Arca.Repo.get_by!(Message, id: approval.message_id, athanor_id: athanor_id)
          }
        end)
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # Clones
  # ---------------------------------------------------------------------------

  @doc """
  Open a clone turn under `parent_turn_id`: its own `turns` row sharing
  the parent's root execution and attempt, the `clone` step in the
  parent (dispatched), and the task as the clone's first row. `attrs`:
  `:role` (the orchestrator), `:task`, `:model`, `:step_id` (an existing
  clone step to bind, else one is recorded), `:fence`, and the clone's
  pins — `:profile_id`, `:consent_id`, `:agent_revision_digest`,
  `:agent_capability_digest` — written with the row so the clone runs
  the bytes that were checked. Answers `{:ok, %{turn, step, task: row}}`.
  """
  @spec open_clone_turn(Context.t(), String.t(), map()) ::
          {:ok, %{turn: Turn.t(), step: TurnStep.t(), task: Message.t()}} | {:error, term()}
  def open_clone_turn(%Context{} = ctx, parent_turn_id, attrs) when is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.open_clone_turn", fn ->
      athanor_id = Context.athanor!(ctx)

      with_seq_retry(fn ->
        Arca.Repo.transaction(fn ->
          parent = own!(athanor_id, parent_turn_id, attrs)
          if parent.status != "running", do: Arca.Repo.rollback(:parent_not_running)
          if parent.parent_turn_id, do: Arca.Repo.rollback(:clone_depth)
          thread = thread!(athanor_id, parent.thread_id)
          now = DateTime.utc_now()
          role = Map.fetch!(attrs, :role)

          step =
            case Map.get(attrs, :step_id) do
              nil ->
                insert_step!(athanor_id, parent, %{
                  kind: "clone",
                  tool: role,
                  action: "clone",
                  dispatch_state: "dispatched",
                  idempotency_key: Map.get(attrs, :idempotency_key)
                })

              step_id ->
                step!(athanor_id, step_id)
            end

          child =
            Arca.Repo.insert!(
              %Turn{}
              |> Ecto.Changeset.change(%{
                id: Cyfr.UUID7.generate_id("trn"),
                athanor_id: athanor_id,
                thread_id: parent.thread_id,
                parent_turn_id: parent.id,
                root_execution_id: parent.root_execution_id,
                attempt: parent.attempt,
                budget_id: parent.budget_id,
                orchestrator: role,
                requested_by: parent.requested_by,
                model: Map.get(attrs, :model),
                profile_id: Map.get(attrs, :profile_id),
                consent_id: Map.get(attrs, :consent_id),
                agent_revision_digest: Map.get(attrs, :agent_revision_digest),
                agent_capability_digest: Map.get(attrs, :agent_capability_digest),
                fence: new_fence(),
                runner_id: Cyfr.Boot.id(),
                status: "running",
                accepted_at: now,
                window_upto_seq: 0
              })
            )

          task =
            Arca.ThreadStorage.insert_message!(ctx, thread, %{
              author: Message.agent_author(),
              kind: "text",
              content: Map.get(attrs, :task, ""),
              payload: %{"as" => "task", "role" => role, "step_id" => step.id},
              turn_id: child.id,
              execution_id: parent.root_execution_id
            })

          event!(athanor_id, parent, "clone.opened", step.id, %{"turn_id" => child.id})
          %{turn: child, step: step, task: task}
        end)
      end)
    end)
  end

  @doc "End a clone turn as `status` (`completed | failed | cancelled | uncertain`)."
  @spec close_clone_turn(Context.t(), String.t(), String.t(), map()) ::
          {:ok, Turn.t()} | {:error, term()}
  def close_clone_turn(%Context{} = ctx, turn_id, status, attrs \\ %{})
      when status in @terminal do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.close_clone_turn", fn ->
      athanor_id = Context.athanor!(ctx)

      Arca.Repo.transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        if is_nil(turn.parent_turn_id), do: Arca.Repo.rollback(:not_a_clone)

        {count, _} =
          from(t in Turn,
            where: t.athanor_id == ^athanor_id and t.id == ^turn_id and t.status in ^@open
          )
          |> Arca.Repo.update_all(
            set: [status: status, error: Map.get(attrs, :error), ended_at: DateTime.utc_now()]
          )

        if count != 1, do: Arca.Repo.rollback(:already_finished)
        turn!(athanor_id, turn_id)
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # The consumption boundary
  # ---------------------------------------------------------------------------

  @doc """
  Move the turn's boundary past every human row attached to it that
  arrived while it worked, and answer those rows in `seq` order: the
  steer the loop drains before its next model request.
  """
  @spec drain_steer(Context.t(), String.t(), map()) :: {:ok, [Message.t()]} | {:error, term()}
  def drain_steer(%Context{} = ctx, turn_id, attrs \\ %{}) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.drain_steer", fn ->
      athanor_id = Context.athanor!(ctx)

      Arca.Repo.transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        rows = steer_rows(athanor_id, turn)

        case rows do
          [] ->
            []

          rows ->
            newest = rows |> Enum.map(& &1.seq) |> Enum.max()

            {1, _} =
              from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn_id)
              |> Arca.Repo.update_all(set: [window_upto_seq: newest])

            rows
        end
      end)
    end)
  end

  @doc "Whether a human row attached to the turn waits past its boundary."
  @spec steer_pending?(Context.t(), String.t()) :: boolean() | {:error, term()}
  def steer_pending?(%Context{} = ctx, turn_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.steer_pending?", fn ->
      athanor_id = Context.athanor!(ctx)
      turn = turn!(athanor_id, turn_id)
      steer_rows(athanor_id, turn) != []
    end)
  end

  @doc """
  The rows a turn may read, in `seq` order: its own rows except undrained
  human steer, plus — behind its boundary — unattached rows and the rows
  of terminal, non-clone turns of the thread. A clone reads its
  own rows only. Rows attached to other open turns are never read.
  """
  @spec projection(Context.t(), String.t()) :: {:ok, [Message.t()]} | {:error, term()}
  def projection(%Context{} = ctx, turn_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.projection", fn ->
      athanor_id = Context.athanor!(ctx)
      turn = turn!(athanor_id, turn_id)
      window = turn.window_upto_seq || 0
      humans = [Message.agent_author(), Message.system_author()]

      rows =
        if turn.parent_turn_id do
          Arca.Repo.all(
            from(m in Message,
              where: m.athanor_id == ^athanor_id and m.thread_id == ^turn.thread_id,
              where: m.turn_id == ^turn_id,
              order_by: [asc: m.seq]
            )
          )
        else
          settled = settled_turns(athanor_id, turn.thread_id)

          Arca.Repo.all(
            from(m in Message,
              where: m.athanor_id == ^athanor_id and m.thread_id == ^turn.thread_id,
              where:
                (m.turn_id == ^turn_id and (m.author in ^humans or m.seq <= ^window)) or
                  (m.seq <= ^window and (is_nil(m.turn_id) or m.turn_id in subquery(settled))),
              order_by: [asc: m.seq]
            )
          )
        end

      {:ok, rows}
    end)
  end

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  @doc """
  The `tool_call` payloads of the steps a turn and its clone turns closed
  with an `ok` outcome, oldest first: what the turn wrote to, read from
  the rows.
  """
  @spec closed_calls(Context.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def closed_calls(%Context{} = ctx, turn_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.closed_calls", fn ->
      athanor_id = Context.athanor!(ctx)

      turns =
        from(t in Turn,
          where:
            t.athanor_id == ^athanor_id and (t.id == ^turn_id or t.parent_turn_id == ^turn_id),
          select: t.id
        )

      payloads =
        Arca.Repo.all(
          from(s in TurnStep,
            join: m in Message,
            on: m.athanor_id == s.athanor_id and m.id == s.message_id,
            where: s.athanor_id == ^athanor_id and s.turn_id in subquery(turns),
            where: s.dispatch_state == "closed" and s.outcome == "ok" and s.kind != "model",
            order_by: [asc: s.seq],
            select: m
          )
        )

      {:ok, Enum.map(payloads, &Arca.ThreadStorage.payload/1)}
    end)
  end

  @doc "One turn of the athanor."
  @spec get(Context.t(), String.t()) :: {:ok, Turn.t()} | {:error, term()}
  def get(%Context{} = ctx, turn_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.get", fn ->
      athanor_id = Context.athanor!(ctx)

      case Arca.Repo.one(from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn_id)) do
        nil -> {:error, :not_found}
        turn -> {:ok, turn}
      end
    end)
  end

  @doc "The turn a message opened, if any."
  @spec turn_of_message(Context.t(), String.t()) :: {:ok, Turn.t()} | {:error, term()}
  def turn_of_message(%Context{} = ctx, message_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.turn_of_message", fn ->
      athanor_id = Context.athanor!(ctx)

      case Arca.Repo.one(
             from(t in Turn, where: t.athanor_id == ^athanor_id and t.message_id == ^message_id)
           ) do
        nil -> {:error, :not_found}
        turn -> {:ok, turn}
      end
    end)
  end

  @doc "The steps of a turn in `seq` order."
  @spec steps(Context.t(), String.t()) :: {:ok, [TurnStep.t()]} | {:error, term()}
  def steps(%Context{} = ctx, turn_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.steps", fn ->
      athanor_id = Context.athanor!(ctx)

      {:ok,
       Arca.Repo.all(
         from(s in TurnStep,
           where: s.athanor_id == ^athanor_id and s.turn_id == ^turn_id,
           order_by: [asc: s.seq]
         )
       )}
    end)
  end

  @doc "One step of the athanor."
  @spec step(Context.t(), String.t()) :: {:ok, TurnStep.t()} | {:error, term()}
  def step(%Context{} = ctx, step_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.step", fn ->
      athanor_id = Context.athanor!(ctx)

      case Arca.Repo.one(
             from(s in TurnStep, where: s.athanor_id == ^athanor_id and s.id == ^step_id)
           ) do
        nil -> {:error, :not_found}
        step -> {:ok, step}
      end
    end)
  end

  @doc "The open turns of a thread (accepted, running or paused), oldest first."
  @spec open_turns(Context.t(), String.t()) :: {:ok, [Turn.t()]} | {:error, term()}
  def open_turns(%Context{} = ctx, thread_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.open_turns", fn ->
      athanor_id = Context.athanor!(ctx)

      {:ok,
       Arca.Repo.all(
         from(t in Turn,
           where: t.athanor_id == ^athanor_id and t.thread_id == ^thread_id,
           where: t.status in ^@open,
           order_by: [asc: t.accepted_at]
         )
       )}
    end)
  end

  @doc """
  Every thread holding an open root turn, across all tenants, as
  `{athanor_id, thread_id}` pairs — the boot's recovery scan.
  System-internal only.
  """
  @spec with_open_turns() :: [{String.t(), String.t()}]
  def with_open_turns do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.with_open_turns", [], fn ->
      # arca:unscoped-ok the boot recovers open turns of every tenant when
      # no tenant context exists yet; system-internal only.
      Arca.Repo.all(
        from(t in Turn,
          where: t.status in ^@open and is_nil(t.parent_turn_id),
          distinct: true,
          select: {t.athanor_id, t.thread_id}
        )
      )
    end)
  end

  @doc "One approval of the athanor."
  @spec approval(Context.t(), String.t()) :: {:ok, Approval.t()} | {:error, term()}
  def approval(%Context{} = ctx, approval_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.approval", fn ->
      athanor_id = Context.athanor!(ctx)

      case Arca.Repo.one(
             from(a in Approval, where: a.athanor_id == ^athanor_id and a.id == ^approval_id)
           ) do
        nil -> {:error, :not_found}
        approval -> {:ok, approval}
      end
    end)
  end

  @doc "The approval a card message references."
  @spec approval_by_message(Context.t(), String.t()) :: {:ok, Approval.t()} | {:error, term()}
  def approval_by_message(%Context{} = ctx, message_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.approval_by_message", fn ->
      athanor_id = Context.athanor!(ctx)

      case Arca.Repo.one(
             from(a in Approval,
               where: a.athanor_id == ^athanor_id and a.message_id == ^message_id
             )
           ) do
        nil -> {:error, :not_found}
        approval -> {:ok, approval}
      end
    end)
  end

  @doc "The pending approvals of a turn, oldest first."
  @spec pending_approvals(Context.t(), String.t()) :: {:ok, [Approval.t()]} | {:error, term()}
  def pending_approvals(%Context{} = ctx, turn_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.pending_approvals", fn ->
      athanor_id = Context.athanor!(ctx)

      {:ok,
       Arca.Repo.all(
         from(a in Approval,
           where: a.athanor_id == ^athanor_id and a.turn_id == ^turn_id,
           where: a.status == "pending",
           order_by: [asc: a.inserted_at]
         )
       )}
    end)
  end

  @doc "The athanor's pending approvals whose `expires_at` passed."
  @spec expired_approvals(Context.t(), DateTime.t()) :: {:ok, [Approval.t()]} | {:error, term()}
  def expired_approvals(%Context{} = ctx, %DateTime{} = now) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.expired_approvals", fn ->
      athanor_id = Context.athanor!(ctx)

      {:ok,
       Arca.Repo.all(
         from(a in Approval,
           where: a.athanor_id == ^athanor_id and a.status == "pending",
           where: not is_nil(a.expires_at) and a.expires_at < ^now,
           order_by: [asc: a.expires_at]
         )
       )}
    end)
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  @doc """
  Run `fun` (a transaction that appends a message) again, up to three
  times, when it fails on the `(thread_id, seq)` unique race.
  """
  @spec with_seq_retry((-> {:ok, term()} | {:error, term()})) :: {:ok, term()} | {:error, term()}
  def with_seq_retry(fun) when is_function(fun, 0), do: with_seq_retry(fun, 3)

  defp with_seq_retry(_fun, 0), do: {:error, :seq_conflict}

  defp with_seq_retry(fun, retries) do
    try do
      fun.()
    rescue
      e in Ecto.InvalidChangesetError ->
        if unique?(e.changeset.errors, :thread_id, "seq"),
          do: with_seq_retry(fun, retries - 1),
          else: {:error, e.changeset}
    end
  end

  # A unique violation on a composite index reports on its first field;
  # the index name tells the races apart.
  defp unique?(errors, field, index_word) do
    errors
    |> Keyword.get_values(field)
    |> Enum.any?(fn
      {_msg, meta} when is_list(meta) ->
        Keyword.get(meta, :constraint) == :unique and
          String.contains?(to_string(Keyword.get(meta, :constraint_name, "")), index_word)

      _ ->
        false
    end)
  end

  # arca:db-raise-ok inside the caller's transaction
  defp close_step!(ctx, athanor_id, turn, step, outcome, attrs) do
    from_states =
      if outcome in ["denied", "skipped"], do: ["dispatched", "proposed"], else: ["dispatched"]

    now = DateTime.utc_now()

    result =
      case Map.get(attrs, :result) do
        nil ->
          nil

        %{} = result ->
          thread = thread!(athanor_id, turn.thread_id)

          Arca.ThreadStorage.insert_message!(ctx, thread, %{
            author: Message.system_author(),
            kind: "tool_result",
            content: Map.get(result, :content, ""),
            payload: Map.merge(Map.get(result, :payload) || %{}, %{"step_id" => step.id}),
            turn_id: turn.id,
            execution_id: Map.get(attrs, :execution_id)
          })
      end

    {count, _} =
      from(s in TurnStep,
        where: s.athanor_id == ^athanor_id and s.id == ^step.id,
        where: s.dispatch_state in ^from_states
      )
      |> Arca.Repo.update_all(
        set: [
          dispatch_state: "closed",
          outcome: outcome,
          result_message_id: result && result.id,
          execution_id: Map.get(attrs, :execution_id) || step.execution_id,
          error: Map.get(attrs, :error),
          ended_at: now
        ]
      )

    if count != 1, do: Arca.Repo.rollback(:not_open)

    event!(athanor_id, turn, "step.closed", step.id, %{
      "outcome" => outcome,
      "execution_id" => Map.get(attrs, :execution_id),
      "result_message_id" => result && result.id
    })

    %{step: step!(athanor_id, step.id), result: result}
  end

  # arca:db-raise-ok inside the caller's transaction
  defp insert_step!(athanor_id, %Turn{} = turn, attrs) do
    seq =
      Arca.Repo.one(
        from(s in TurnStep,
          where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id,
          select: coalesce(max(s.seq), 0)
        )
      ) + 1

    kind = Map.get(attrs, :kind, "tool")
    if kind not in @step_kinds, do: Arca.Repo.rollback({:invalid_step_kind, kind})

    Arca.Repo.insert!(%TurnStep{
      id: Map.get(attrs, :id) || Cyfr.UUID7.generate_id("stp"),
      athanor_id: athanor_id,
      turn_id: turn.id,
      seq: seq,
      kind: kind,
      idempotency_key: Map.get(attrs, :idempotency_key),
      tool: Map.get(attrs, :tool),
      action: Map.get(attrs, :action),
      dispatch_state: Map.get(attrs, :dispatch_state, "proposed"),
      message_id: Map.get(attrs, :message_id),
      authority_digest: Map.get(attrs, :authority_digest),
      request_digest: Map.get(attrs, :request_digest),
      proposal_digest: Map.get(attrs, :proposal_digest),
      recovery: Map.get(attrs, :recovery),
      excluded: encode(Map.get(attrs, :excluded)),
      child_execution_id: Map.get(attrs, :child_execution_id),
      started_at: if(Map.get(attrs, :dispatch_state) == "dispatched", do: DateTime.utc_now())
    })
  end

  # arca:db-raise-ok inside the caller's transaction
  defp event!(_athanor_id, %Turn{root_execution_id: nil}, _type, _step_id, _data), do: :ok

  defp event!(athanor_id, %Turn{} = turn, type, step_id, data) do
    Arca.ExecutionEvents.append!(athanor_id, turn.root_execution_id, type,
      turn_id: turn.id,
      step_id: step_id,
      data: reject_nil(data)
    )

    :ok
  end

  # Move the root execution between statuses, fenced on the turn's own
  # attempt being the pointer. `error:` sets the message on a terminal move.
  # arca:db-raise-ok inside the caller's transaction
  defp execution_status!(athanor_id, execution_id, from, to, opts \\ [])

  defp execution_status!(_athanor_id, nil, _from, _to, _opts), do: :ok

  defp execution_status!(athanor_id, execution_id, from, to, opts) do
    from = List.wrap(from)

    sets =
      if to in Arca.Execution.terminal_statuses(),
        do: [
          status: to,
          completed_at: DateTime.utc_now(),
          error_message: Keyword.get(opts, :error)
        ],
        else: [status: to]

    {count, _} =
      from(e in Arca.Execution,
        where: e.id == ^execution_id and e.athanor_id == ^athanor_id,
        where: e.status in ^from
      )
      |> Arca.Repo.update_all(set: sets)

    if count != 1, do: Arca.Repo.rollback({:execution_not_in, from})
    :ok
  end

  defp attempt_end("completed"), do: {"completed", "ok"}
  defp attempt_end("failed"), do: {"failed", "error"}
  defp attempt_end("cancelled"), do: {"cancelled", "cancelled"}
  defp attempt_end("uncertain"), do: {"failed", "uncertain"}

  defp status_of("uncertain"), do: "failed"
  defp status_of(status), do: status

  # The highest seq a turn may read when it starts: its own initiating
  # message, and every unattached row or row of a settled turn.
  # arca:db-raise-ok inside the caller's transaction
  defp boundary(athanor_id, %Turn{} = turn) do
    settled = settled_turns(athanor_id, turn.thread_id)

    history =
      Arca.Repo.one(
        from(m in Message,
          where: m.athanor_id == ^athanor_id and m.thread_id == ^turn.thread_id,
          where: is_nil(m.turn_id) or m.turn_id in subquery(settled),
          select: coalesce(max(m.seq), 0)
        )
      )

    own =
      if turn.message_id do
        Arca.Repo.one(
          from(m in Message,
            where: m.athanor_id == ^athanor_id and m.id == ^turn.message_id,
            select: m.seq
          )
        ) || 0
      else
        0
      end

    max(history, own)
  end

  defp settled_turns(athanor_id, thread_id) do
    from(t in Turn,
      where: t.athanor_id == ^athanor_id and t.thread_id == ^thread_id,
      where: t.status in ^@terminal and is_nil(t.parent_turn_id),
      select: t.id
    )
  end

  # arca:db-raise-ok inside the caller's transaction
  defp steer_rows(athanor_id, %Turn{} = turn) do
    window = turn.window_upto_seq || 0
    reserved = [Message.agent_author(), Message.system_author()]

    Arca.Repo.all(
      from(m in Message,
        where: m.athanor_id == ^athanor_id and m.turn_id == ^turn.id,
        where: m.author not in ^reserved and m.seq > ^window,
        order_by: [asc: m.seq]
      )
    )
  end

  # arca:db-raise-ok inside the caller's transaction
  defp turn!(athanor_id, turn_id) do
    Arca.Repo.one(from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn_id)) ||
      Arca.Repo.rollback(:turn_not_found)
  end

  # arca:db-raise-ok inside the caller's transaction
  defp step!(athanor_id, step_id) do
    Arca.Repo.one(from(s in TurnStep, where: s.athanor_id == ^athanor_id and s.id == ^step_id)) ||
      Arca.Repo.rollback(:step_not_found)
  end

  # arca:db-raise-ok inside the caller's transaction
  defp approval!(athanor_id, approval_id) do
    Arca.Repo.one(
      from(a in Approval, where: a.athanor_id == ^athanor_id and a.id == ^approval_id)
    ) ||
      Arca.Repo.rollback(:approval_not_found)
  end

  # arca:db-raise-ok inside the caller's transaction
  defp thread!(athanor_id, thread_id) do
    Arca.Repo.get_by(Thread, id: thread_id, athanor_id: athanor_id) ||
      Arca.Repo.rollback(:thread_not_found)
  end

  # The first write of a runner-owned transaction: the turn row, updated on
  # the fence the runner holds, which takes the row's lock for the rest of
  # the transaction. A fence another process moved matches no row.
  # arca:db-raise-ok inside the caller's transaction
  defp own!(athanor_id, turn_id, attrs) do
    fence = held_fence!(attrs)

    case from(t in Turn,
           where: t.athanor_id == ^athanor_id and t.id == ^turn_id and t.fence == ^fence
         )
         |> Arca.Repo.update_all(set: [fence: fence]) do
      {1, _} -> turn!(athanor_id, turn_id)
      {0, _} -> Arca.Repo.rollback(:superseded)
    end
  end

  # `own!/3` for a write keyed by one of the turn's steps.
  # arca:db-raise-ok inside the caller's transaction
  defp own_step!(athanor_id, step_id, attrs) do
    turn_id =
      Arca.Repo.one(
        from(s in TurnStep,
          where: s.athanor_id == ^athanor_id and s.id == ^step_id,
          select: s.turn_id
        )
      ) || Arca.Repo.rollback(:step_not_found)

    own!(athanor_id, turn_id, attrs)
  end

  # A host transition that takes the turn from whoever held it: the fence
  # the caller read is replaced by the next one in the same write, so of two
  # transitions racing over one turn only the first lands.
  # arca:db-raise-ok inside the caller's transaction
  defp take!(athanor_id, turn_id, attrs) do
    fence = held_fence!(attrs)

    case from(t in Turn,
           where: t.athanor_id == ^athanor_id and t.id == ^turn_id and t.fence == ^fence
         )
         |> Arca.Repo.update_all(set: [fence: new_fence()]) do
      {1, _} -> turn!(athanor_id, turn_id)
      {0, _} -> Arca.Repo.rollback(:superseded)
    end
  end

  defp held_fence!(attrs) do
    case Map.get(attrs, :fence) do
      fence when is_binary(fence) and fence != "" -> fence
      _ -> Arca.Repo.rollback(:fence_required)
    end
  end

  # arca:db-raise-ok inside the caller's transaction
  defp open_turn_of!(athanor_id, turn_id) do
    case turn!(athanor_id, turn_id) do
      %Turn{status: status} = turn when status in @open -> turn
      _ -> Arca.Repo.rollback(:turn_over)
    end
  end

  defp new_fence, do: Cyfr.UUID7.generate_id("fnc")

  defp encode(nil), do: nil
  defp encode(value) when is_binary(value), do: value
  defp encode(value), do: Jason.encode!(value)

  defp reject_nil(map) when is_map(map) do
    map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
  end
end
