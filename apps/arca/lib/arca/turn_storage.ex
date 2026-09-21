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
  over compares the fence it read and raises it by one in the same write,
  so fences only grow.
  A step is proposed before its effect (`record_response/4`), flipped to
  `dispatched` in its own commit (`dispatch_step/3`), and closed with its
  result row, outcome and event together (`close_step/4`). Pause and
  resume flip the turn, its root attempt and its root execution in one
  transaction; `finish/4` is the one terminal write.

  Multi-row writes that append a message run under `with_seq_retry/1`:
  the `(thread_id, seq)` race surfaces as a changeset raise inside
  the transaction and the whole transaction is retried, since a retry
  inside an aborted Postgres transaction cannot land.

  ## The thread claim

  Which root turn may run at all is the thread's, not the turn's:
  `threads.active_turn_id` (`Arca.ThreadStorage`). `start/3` takes it in
  the transaction that moves the turn to `running`, naming the consumed
  sequence the caller read; `finish/4` and `suspend/3` give it up;
  `takeover/3`, `recover/3` and `pause_recovered/3` take it from a turn
  whose holder is not a live member, in the same transaction that counts
  the recovery — so a member that did not take the claim cannot spend one.
  An approval pause keeps the claim: the turn is still this member's work.
  Clone turns hold no claim; the root they run under does.
  """

  import Ecto.Query
  # Every function takes the `Cyfr.Actor` first and matches it in the
  # head; an actor whose athanor is nil OR the empty string is
  # `{:error, :no_athanor}` before any query, and `bind_child!/4`, which
  # runs inside admission's transaction, raises instead., only: [from: 2]

  alias Arca.Schemas.{Approval, Thread, Message, Turn, TurnStep}

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
  - `:turn` — `%{agent, requested_by, model, options}` to open an
    `accepted` turn keyed by the message; `nil` for room content.
  - `:steer_turn_id` — attach the message to an open turn of the thread
    instead; a turn that has ended answers `{:error, :turn_over}`. The
    turn's row is locked before the message is written, so a steer and
    the turn's terminal write serialize: the steer lands on a turn that
    will answer it (`finish/4`), or is refused.

  Answers `{:ok, %{message: row, turn: row | nil}}`. A `client_id` this
  thread already accepted answers `{:error, :duplicate_client_id}`,
  a message `id` already taken `{:error, :message_id_reused}`
  (the caller reads the existing acceptance with `accepted/3`); a
  message that already opened a turn answers `{:error, :turn_exists}`.
  """
  @spec accept_message(Cyfr.Actor.t(), String.t(), map()) ::
          {:ok, %{message: Message.t(), turn: Turn.t() | nil}} | {:error, term()}
  def accept_message(%Cyfr.Actor{athanor_id: athanor_id} = actor, thread_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.accept_message", fn ->
      message = Map.fetch!(attrs, :message)

      with_seq_retry(fn ->
        Arca.Repo.transaction(fn ->
          thread = thread!(athanor_id, thread_id)
          steer_id = Map.get(attrs, :steer_turn_id)
          opens = Map.get(attrs, :turn)

          steered =
            if is_nil(opens) and steer_id, do: hold_open_turn!(athanor_id, thread, steer_id)

          row =
            Arca.ThreadStorage.insert_message!(
              actor,
              thread,
              Map.put(message, :turn_id, steer_id)
            )

          turn =
            case opens do
              nil -> steered
              %{} = t -> open_turn!(athanor_id, thread, row, t)
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

  def accept_message(%Cyfr.Actor{}, _thread_id, _attrs), do: {:error, :no_athanor}

  @doc "The acceptance a sender's `client_id` already produced: its message and turn."
  @spec accepted(Cyfr.Actor.t(), String.t(), String.t()) ::
          {:ok, %{message: Message.t(), turn: Turn.t() | nil}} | {:error, term()}
  def accepted(%Cyfr.Actor{athanor_id: athanor_id} = actor, thread_id, client_id)
      when is_binary(athanor_id) and athanor_id != "" do
    with {:ok, message} <-
           Arca.ThreadStorage.get_by_client_id(actor, thread_id, client_id) do
      Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.accepted", fn ->
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

  def accepted(%Cyfr.Actor{}, _thread_id, _client_id), do: {:error, :no_athanor}

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
          agent: Map.get(attrs, :agent),
          requested_by: Map.get(attrs, :requested_by),
          model: Map.get(attrs, :model),
          options: encode(Map.get(attrs, :options)),
          fence: 1,
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
      agent: Map.get(attrs, :agent)
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

  The thread's claim is taken in the same transaction, naming the
  consumed sequence in `:turn_seq` — the value the caller read before it
  decided this turn runs next. A claim refused because a peer accepted
  the next message first answers `{:error, :stale}`, and the caller reads
  the thread again; one refused because another turn holds the thread
  answers `{:error, {:busy, turn_id}}`. Without `:turn_seq` the sequence
  the transaction reads is used, which checks the holder and not the
  caller's view of the thread.
  """
  @spec start(Cyfr.Actor.t(), String.t(), map()) :: {:ok, Turn.t()} | {:error, term()}
  def start(%Cyfr.Actor{athanor_id: athanor_id}, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.start", fn ->
      Arca.Repo.transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        claim_thread!(athanor_id, turn, attrs)
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

  def start(%Cyfr.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  @doc """
  Pin the exact catalyst release the turn runs on, under `:fence`. A turn
  pins once: pinning the release already pinned answers the turn, and a
  different one is `{:error, :catalyst_pinned}`.
  """
  @spec pin_catalyst(Cyfr.Actor.t(), String.t(), String.t(), map()) ::
          {:ok, Turn.t()} | {:error, term()}
  def pin_catalyst(%Cyfr.Actor{athanor_id: athanor_id}, turn_id, catalyst_ref, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(catalyst_ref) and
             is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.pin_catalyst", fn ->
      Arca.Repo.transaction(fn ->
        case own!(athanor_id, turn_id, attrs) do
          %Turn{catalyst_ref: nil} ->
            {1, _} =
              from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn_id)
              |> Arca.Repo.update_all(set: [catalyst_ref: catalyst_ref])

            turn!(athanor_id, turn_id)

          %Turn{catalyst_ref: ^catalyst_ref} = turn ->
            turn

          %Turn{} ->
            Arca.Repo.rollback(:catalyst_pinned)
        end
      end)
    end)
  end

  def pin_catalyst(%Cyfr.Actor{}, _turn_id, _catalyst_ref, _attrs), do: {:error, :no_athanor}

  @doc """
  Pause a running turn: the turn, its root attempt and its root execution
  leave `running` together. `attrs`: `:fence`, `:reason`
  (`"approval" | "launch"`), `:launch_step_id`. The running interval is
  added to `active_ms`. Event `turn.paused`.
  """
  @spec pause(Cyfr.Actor.t(), String.t(), map()) :: {:ok, Turn.t()} | {:error, term()}
  def pause(actor, turn_id, attrs \\ %{})

  def pause(%Cyfr.Actor{athanor_id: athanor_id}, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.pause", fn ->
      Arca.Repo.transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        if turn.status != "running", do: Arca.Repo.rollback(:not_running)

        ran = Arca.ExecutionAttempts.pause!(Cyfr.Actor.in_athanor(athanor_id), turn.attempt) || 0
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

  def pause(%Cyfr.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  @doc """
  Resume a paused turn with a fresh lease: the turn, its root attempt and
  its root execution return to `running` together. Event `turn.resumed`.
  """
  @spec resume(Cyfr.Actor.t(), String.t(), map()) :: {:ok, Turn.t()} | {:error, term()}
  def resume(actor, turn_id, attrs \\ %{})

  def resume(%Cyfr.Actor{athanor_id: athanor_id}, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.resume", fn ->
      Arca.Repo.transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        if turn.status != "paused", do: Arca.Repo.rollback(:not_paused)

        until = Map.get(attrs, :lease_until) || Arca.ExecutionAttempts.lease_until()

        if Arca.ExecutionAttempts.resume!(Cyfr.Actor.in_athanor(athanor_id), turn.attempt, until) !=
             1,
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

  def resume(%Cyfr.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  @doc """
  Append one row the turn owns but no step produced — a compaction, an
  aborted mark, a system note — inside the turn's fence. `attrs`: the
  message's own fields plus `:fence`.

  These rows are part of what the next request reads, so a runner whose
  fence has moved must not be able to add one: a superseded loop appending
  a compaction would change the projection its successor is working from.
  """
  @spec append_turn_row(Cyfr.Actor.t(), String.t(), map()) ::
          {:ok, Message.t()} | {:error, term()}
  def append_turn_row(%Cyfr.Actor{athanor_id: athanor_id} = actor, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.append_turn_row", fn ->
      Arca.Repo.transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        thread = thread!(athanor_id, turn.thread_id)

        Arca.ThreadStorage.insert_message!(
          actor,
          thread,
          attrs |> Map.drop([:fence]) |> Map.put(:turn_id, turn.id)
        )
      end)
    end)
  end

  def append_turn_row(%Cyfr.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  @doc """
  End a turn: the one terminal transaction. `status` is
  `completed | failed | cancelled | uncertain`; `attrs`: `:fence`,
  `:error`. The root attempt is closed with the matching outcome, the
  root execution leaves `running`/`paused`, the reservation is released
  and the open running interval is added to `active_ms`. A turn already
  over is answered `{:error, :already_finished}`; a turn with no root yet
  (still `accepted`) closes on its own. A turn with a steer past its
  boundary refuses `completed` with `{:error, :steer_pending}`: its loop
  goes on to answer the steer. Event `turn.<status>`.
  """
  @spec finish(Cyfr.Actor.t(), String.t(), String.t(), map()) ::
          {:ok, Turn.t()} | {:error, term()}
  def finish(actor, turn_id, status, attrs \\ %{})

  def finish(%Cyfr.Actor{athanor_id: athanor_id}, turn_id, status, attrs)
      when is_binary(athanor_id) and athanor_id != "" and status in @terminal do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.finish", fn ->
      Arca.Repo.transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        if turn.status in @terminal, do: Arca.Repo.rollback(:already_finished)

        if status == "completed" and steer_rows(athanor_id, turn) != [],
          do: Arca.Repo.rollback(:steer_pending)

        ran =
          if turn.attempt do
            {attempt_state, outcome} = attempt_end(status)

            Arca.ExecutionAttempts.close!(
              Cyfr.Actor.in_athanor(athanor_id),
              turn.attempt,
              attempt_state,
              outcome
            ) || 0
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

          Arca.BudgetReservations.close!(
            Cyfr.Actor.in_athanor(athanor_id),
            turn.root_execution_id
          )
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

        # A turn that is over holds nothing: the claim goes back before the
        # commit, in the same transaction, so the thread is free the moment
        # the end is visible and no second statement can be lost.
        Arca.ThreadStorage.release_all!(
          Cyfr.Actor.in_athanor(athanor_id),
          turn.thread_id,
          turn_id
        )

        turn = turn!(athanor_id, turn_id)
        event!(athanor_id, turn, "turn." <> status, nil, %{"error" => Map.get(attrs, :error)})
        turn
      end)
    end)
  end

  def finish(%Cyfr.Actor{}, _turn_id, _status, _attrs), do: {:error, :no_athanor}

  @doc """
  Set a running or paused turn down, keeping every row it has written and
  giving up the thread's claim, so any member may pick it up
  (`turn.suspend`). `attrs`: `:fence` (the one the caller read) and
  `:reason`.

  The fence is raised first, so the runner that held the turn writes
  nothing afterwards. A running turn's root attempt and root execution
  leave `running` with it and its open running interval is added to
  `active_ms`, exactly as an approval pause does. What suspending adds to
  a pause is the release: an approval pause keeps `active_turn_id`
  because the turn is still this member's work, while a suspended turn is
  nobody's until a member recovers it. Event `turn.paused`, reason
  `suspended`.
  """
  @spec suspend(Cyfr.Actor.t(), String.t(), map()) :: {:ok, Turn.t()} | {:error, term()}
  def suspend(%Cyfr.Actor{athanor_id: athanor_id}, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.suspend", fn ->
      Arca.Repo.transaction(fn ->
        turn = take!(athanor_id, turn_id, attrs)
        if turn.status not in ["running", "paused"], do: Arca.Repo.rollback(:not_running)
        now = DateTime.utc_now()

        ran =
          if turn.status == "running" do
            ran =
              Arca.ExecutionAttempts.pause!(Cyfr.Actor.in_athanor(athanor_id), turn.attempt) || 0

            execution_status!(athanor_id, turn.root_execution_id, "running", "paused")
            ran
          else
            0
          end

        {1, _} =
          from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn_id)
          |> Arca.Repo.update_all(
            set: [
              status: "paused",
              paused_at: now,
              paused_reason: "suspended",
              launch_step_id: nil,
              active_ms: turn.active_ms + ran
            ]
          )

        Arca.ThreadStorage.release_all!(
          Cyfr.Actor.in_athanor(athanor_id),
          turn.thread_id,
          turn_id
        )

        turn = turn!(athanor_id, turn_id)

        event!(athanor_id, turn, "turn.paused", nil, %{
          "reason" => "suspended",
          "detail" => Map.get(attrs, :reason)
        })

        turn
      end)
    end)
  end

  def suspend(%Cyfr.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  @doc """
  Take an open turn no live member is running and carry it on
  (`turn.recover`): the thread's claim and the recovery count in one
  transaction, so a member that did not take the claim cannot spend a
  recovery. `attrs`: `:fence` (the one the caller read) and
  `:lease_until`.

  The fence is compared and raised first. The claim is admitted only by a
  thread nobody holds, one this turn already holds, or one whose holder's
  boot is no longer a live member — never by a live peer's, which is
  `{:error, :busy}`. A running turn is adopted as `takeover/3` adopts
  one: the predecessor attempt retired, a successor opened, the
  predecessor's unaccounted interval added. A paused turn keeps the
  attempt its pause left; the loop that continues it resumes that one.
  Refused `{:error, :recovery_exhausted}` past the cap and
  `{:error, :not_open}` for a turn that is over.
  """
  @spec recover(Cyfr.Actor.t(), String.t(), map()) :: {:ok, Turn.t()} | {:error, term()}
  def recover(actor, turn_id, attrs \\ %{})

  def recover(%Cyfr.Actor{athanor_id: athanor_id}, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.recover", fn ->
      Arca.Repo.transaction(fn ->
        turn = take!(athanor_id, turn_id, attrs)
        if turn.status not in @open, do: Arca.Repo.rollback(:not_open)
        if turn.recovery_attempts >= @recovery_cap, do: Arca.Repo.rollback(:recovery_exhausted)
        if turn.parent_turn_id, do: Arca.Repo.rollback(:clone)

        thread = thread!(athanor_id, turn.thread_id)
        Arca.ThreadStorage.take_claim!(Cyfr.Actor.in_athanor(athanor_id), thread.id, turn_id)

        adopted =
          if turn.status == "running" and turn.root_execution_id,
            do: adopt_root!(athanor_id, turn, attrs),
            else: %{sets: [], ran_ms: 0, attempt: nil}

        {1, _} =
          from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn_id)
          |> Arca.Repo.update_all(
            set:
              adopted.sets ++
                [
                  runner_id: Cyfr.Boot.id(),
                  recovery_attempts: turn.recovery_attempts + 1,
                  active_ms: turn.active_ms + adopted.ran_ms
                ]
          )

        turn = turn!(athanor_id, turn_id)
        event!(athanor_id, turn, "turn.recovered", nil, %{"attempt" => adopted.attempt})
        turn
      end)
    end)
  end

  def recover(%Cyfr.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  @doc """
  Take over a running turn another runner lost: the one place a
  successor attempt is opened. `attrs`: `:fence` (the one the caller read)
  and `:lease_until`. The turn's fence is compared and renewed first, then
  the thread's claim is taken — never from a live peer, which is
  `{:error, :busy}` — the predecessor is retired, the successor opened
  with the next fence and the pointer moved, `recovery_attempts` counted
  and the predecessor's unaccounted running interval added. The claim and
  the count are the one transaction, so a member that did not take the
  claim cannot spend a recovery. Refused
  `{:error, :recovery_exhausted}` past the cap and `{:error, :not_open}`
  for a turn that is over.
  """
  @spec takeover(Cyfr.Actor.t(), String.t(), map()) :: {:ok, Turn.t()} | {:error, term()}
  def takeover(actor, turn_id, attrs \\ %{})

  def takeover(%Cyfr.Actor{athanor_id: athanor_id}, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.takeover", fn ->
      Arca.Repo.transaction(fn ->
        turn = take!(athanor_id, turn_id, attrs)
        if turn.status not in ["running", "paused"], do: Arca.Repo.rollback(:not_open)
        if turn.recovery_attempts >= @recovery_cap, do: Arca.Repo.rollback(:recovery_exhausted)
        if is_nil(turn.root_execution_id), do: Arca.Repo.rollback(:no_root)

        thread = thread!(athanor_id, turn.thread_id)
        Arca.ThreadStorage.take_claim!(Cyfr.Actor.in_athanor(athanor_id), thread.id, turn_id)

        %{sets: sets, ran_ms: ran, attempt: attempt} = adopt_root!(athanor_id, turn, attrs)

        {1, _} =
          from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn_id)
          |> Arca.Repo.update_all(
            set:
              sets ++
                [
                  runner_id: Cyfr.Boot.id(),
                  recovery_attempts: turn.recovery_attempts + 1,
                  active_ms: turn.active_ms + ran
                ]
          )

        turn = turn!(athanor_id, turn_id)
        event!(athanor_id, turn, "turn.recovered", nil, %{"attempt" => attempt})
        turn
      end)
    end)
  end

  def takeover(%Cyfr.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  # The attempt half of a takeover: the predecessor retired, a successor
  # opened under this boot, the root execution back to `running`. Answers
  # what the turn row must be set to with it, the predecessor's
  # unaccounted interval, and the successor's id.
  # arca:db-raise-ok inside the caller's transaction
  defp adopt_root!(athanor_id, %Turn{} = turn, attrs) do
    %{attempt: successor, ran_ms: ran} =
      Arca.ExecutionAttempts.takeover!(
        Cyfr.Actor.in_athanor(athanor_id),
        turn.root_execution_id,
        boot_id: Cyfr.Boot.id(),
        lease_until: Map.get(attrs, :lease_until) || Arca.ExecutionAttempts.lease_until()
      )

    execution_status!(
      athanor_id,
      turn.root_execution_id,
      ["running", "paused", "failed"],
      "running"
    )

    %{
      sets: [
        status: "running",
        attempt: successor.attempt,
        paused_at: nil,
        paused_reason: nil,
        launch_step_id: nil
      ],
      ran_ms: ran,
      attempt: successor.attempt
    }
  end

  @doc """
  Raise the fence of the turn and of its open clones, and mark every step
  either has dispatched cancel-requested, before the loop is stopped: a
  later write from an old fence and a later admission of those steps are
  refused. `attrs`: `:fence`, the one the caller read. Answers the turn
  with its new fence.
  """
  @spec supersede(Cyfr.Actor.t(), String.t(), map()) :: {:ok, Turn.t()} | {:error, term()}
  def supersede(%Cyfr.Actor{athanor_id: athanor_id}, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.supersede", fn ->
      Arca.Repo.transaction(fn ->
        turn = take!(athanor_id, turn_id, attrs)
        if turn.status not in @open, do: Arca.Repo.rollback(:not_open)
        now = DateTime.utc_now()
        clones = open_clone_ids(athanor_id, turn_id)

        from(s in TurnStep,
          where:
            s.athanor_id == ^athanor_id and
              (s.turn_id == ^turn_id or s.turn_id in subquery(clones)),
          where: s.dispatch_state == "dispatched" and is_nil(s.cancel_requested_at)
        )
        |> Arca.Repo.update_all(set: [cancel_requested_at: now])

        turn!(athanor_id, turn_id)
      end)
    end)
  end

  def supersede(%Cyfr.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

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
  @spec pause_uncertain(Cyfr.Actor.t(), String.t(), map()) ::
          {:ok, %{turn: Turn.t(), aborted: Message.t()}} | {:error, term()}
  def pause_uncertain(%Cyfr.Actor{athanor_id: athanor_id} = actor, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.pause_uncertain", fn ->
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
                ran =
                  Arca.ExecutionAttempts.pause!(Cyfr.Actor.in_athanor(athanor_id), turn.attempt) ||
                    0

                execution_status!(athanor_id, turn.root_execution_id, "running", "paused")
                ran

              %Turn{status: "paused", paused_reason: "launch"} ->
                0

              _ ->
                Arca.Repo.rollback(:not_open)
            end

          content = Map.get(attrs, :content, @aborted_content)
          cancel_dispatched!(athanor_id, turn, step.id, now)
          _skipped = skip_proposed!(actor, athanor_id, turn, content)
          aborted = aborted_row!(actor, athanor_id, turn, content)

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

  def pause_uncertain(%Cyfr.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  @doc """
  A running turn a dead runner left holding an unacknowledged
  uncertainty is set down as paused `uncertain`, resumable: the
  predecessor attempt is retired with its running interval bounded by
  its lease (as a takeover does) and a successor is opened already
  paused, without counting a recovery; every dispatched step is settled
  by `TurnStep.unresolved/1`, every proposed step skipped, and — when an
  `uncertain` step is not yet covered — a covering `turn_aborted` row
  appended and the boundary moved to it. `attrs`: `:fence` (the one the caller read),
  `:content`. Answers the turn.
  """
  @spec pause_recovered(Cyfr.Actor.t(), String.t(), map()) :: {:ok, Turn.t()} | {:error, term()}
  def pause_recovered(%Cyfr.Actor{athanor_id: athanor_id} = actor, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.pause_recovered", fn ->
      with_seq_retry(fn ->
        Arca.Repo.transaction(fn ->
          turn = take!(athanor_id, turn_id, attrs)
          if turn.status != "running", do: Arca.Repo.rollback(:not_running)
          if is_nil(turn.root_execution_id), do: Arca.Repo.rollback(:no_root)

          # Setting a turn down is recovery, so it is admitted by the same
          # row: never from a live peer, and in this transaction.
          thread = thread!(athanor_id, turn.thread_id)
          Arca.ThreadStorage.take_claim!(Cyfr.Actor.in_athanor(athanor_id), thread.id, turn_id)

          now = DateTime.utc_now()

          %{attempt: successor, ran_ms: ran} =
            Arca.ExecutionAttempts.takeover!(
              Cyfr.Actor.in_athanor(athanor_id),
              turn.root_execution_id,
              boot_id: Cyfr.Boot.id(),
              lease_until: Arca.ExecutionAttempts.lease_until()
            )

          _ = Arca.ExecutionAttempts.pause!(Cyfr.Actor.in_athanor(athanor_id), successor.attempt)

          execution_status!(
            athanor_id,
            turn.root_execution_id,
            ["running", "paused", "failed"],
            "paused"
          )

          content = Map.get(attrs, :content, @aborted_content)

          Arca.Repo.all(
            from(s in TurnStep,
              where: s.athanor_id == ^athanor_id and s.turn_id == ^turn_id,
              where: s.dispatch_state == "dispatched"
            )
          )
          |> Enum.each(&settle_unresolved!(actor, athanor_id, turn, &1, content))

          _skipped = skip_proposed!(actor, athanor_id, turn, content)

          window =
            if uncovered_uncertain(athanor_id, turn) != [],
              do: aborted_row!(actor, athanor_id, turn, content).seq,
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

  def pause_recovered(%Cyfr.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  @doc """
  Whether the turn holds an uncertainty nobody has acknowledged: an
  `uncertain` step no `turn_aborted` row covers, or a covering row with
  no later row from the turn's sender. A covered, acknowledged
  uncertainty is a restricted continuation, not an open episode.
  """
  @spec unacknowledged_episode?(Cyfr.Actor.t(), String.t()) :: boolean() | {:error, term()}
  def unacknowledged_episode?(%Cyfr.Actor{athanor_id: athanor_id}, turn_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.unacknowledged_episode?", fn ->
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

  def unacknowledged_episode?(%Cyfr.Actor{}, _turn_id),
    do: Arca.QueryHelpers.no_athanor!("Arca.TurnStorage.unacknowledged_episode?/2")

  @doc "Whether any step of the turn is `uncertain`: the continuation runs replay-safe reads only."
  @spec restricted?(Cyfr.Actor.t(), String.t()) :: boolean() | {:error, term()}
  def restricted?(%Cyfr.Actor{athanor_id: athanor_id}, turn_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.restricted?", fn ->
      Arca.Repo.exists?(
        from(s in TurnStep,
          where: s.athanor_id == ^athanor_id and s.turn_id == ^turn_id,
          where: s.dispatch_state == "uncertain"
        )
      )
    end)
  end

  def restricted?(%Cyfr.Actor{}, _turn_id),
    do: Arca.QueryHelpers.no_athanor!("Arca.TurnStorage.restricted?/2")

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
  defp aborted_row!(actor, athanor_id, %Turn{} = turn, content) do
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

    Arca.ThreadStorage.insert_message!(actor, thread, %{
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
  `:purpose` (default `chat`), `:tool`, `:action`, `:idempotency_key`, `:authority_digest`,
  `:request_digest`, `:proposal_digest`, `:recovery`, `:excluded` (a
  list), `:message_id`, `:child_execution_id`, `:dispatch_state`
  (default `proposed`), `:fence`.
  """
  @spec put_step(Cyfr.Actor.t(), String.t(), map()) :: {:ok, TurnStep.t()} | {:error, term()}
  def put_step(%Cyfr.Actor{athanor_id: athanor_id}, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.put_step", fn ->
      Arca.Repo.transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        insert_step!(athanor_id, turn, attrs)
      end)
    end)
  end

  def put_step(%Cyfr.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  @doc """
  Persist a model response before any of its calls run: the model step
  closes with its usage, the reply and every tool call become message
  rows, every call becomes a `proposed` step, and one event records it.
  `response`: `:text`, `:usage`, `:stop_reason`, `:tool_calls` — each
  `%{tool_call_id, name, tool, action, arguments, provider_data, kind,
  recovery, child_execution_id}`; `:fence`. Answers
  `{:ok, %{text: row | nil, calls: [%{message: row, step: step}]}}`.
  """
  @spec record_response(Cyfr.Actor.t(), String.t(), String.t(), map()) ::
          {:ok, %{text: Message.t() | nil, calls: [map()]}} | {:error, term()}
  def record_response(
        %Cyfr.Actor{athanor_id: athanor_id} = actor,
        turn_id,
        model_step_id,
        response
      )
      when is_binary(athanor_id) and athanor_id != "" and is_map(response) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.record_response", fn ->
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
                Arca.ThreadStorage.insert_message!(actor, thread, %{
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

          # A call serves what the request that proposed it served.
          purpose = step!(athanor_id, model_step_id).purpose

          calls =
            response
            |> Map.get(:tool_calls, [])
            |> Enum.map(fn call ->
              row =
                Arca.ThreadStorage.insert_message!(actor, thread, %{
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
                  purpose: purpose,
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

  def record_response(%Cyfr.Actor{}, _turn_id, _model_step_id, _response),
    do: {:error, :no_athanor}

  @doc """
  Flip a proposed step to `dispatched` in its own commit. Answers the
  step, or `{:error, :not_proposed}` when it was not proposed (dispatched
  already, closed, or cancel-requested).
  """
  @spec dispatch_step(Cyfr.Actor.t(), String.t(), map()) :: {:ok, TurnStep.t()} | {:error, term()}
  def dispatch_step(actor, step_id, attrs \\ %{})

  def dispatch_step(%Cyfr.Actor{athanor_id: athanor_id}, step_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.dispatch_step", fn ->
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

  def dispatch_step(%Cyfr.Actor{}, _step_id, _attrs), do: {:error, :no_athanor}

  @doc """
  Close a step with its result: the `tool_result` row, the step's
  `outcome`, `execution_id` and error, and the `step.closed` event, in
  one transaction. `attrs`: `:result` (`%{content, payload}` for the
  row; omitted for a step that produced none), `:execution_id`, `:error`,
  `:fence`. A step closes from `dispatched`, or from `proposed` for
  `denied` and `skipped`.
  """
  @spec close_step(Cyfr.Actor.t(), String.t(), String.t(), map()) ::
          {:ok, %{step: TurnStep.t(), result: Message.t() | nil}} | {:error, term()}
  def close_step(actor, step_id, outcome, attrs \\ %{})

  def close_step(%Cyfr.Actor{athanor_id: athanor_id} = actor, step_id, outcome, attrs)
      when is_binary(athanor_id) and athanor_id != "" and outcome in @outcomes do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.close_step", fn ->
      with_seq_retry(fn ->
        Arca.Repo.transaction(fn ->
          turn = own_step!(athanor_id, step_id, attrs)
          step = step!(athanor_id, step_id)
          close_step!(actor, athanor_id, turn, step, outcome, attrs)
        end)
      end)
    end)
  end

  def close_step(%Cyfr.Actor{}, _step_id, _outcome, _attrs), do: {:error, :no_athanor}

  @doc """
  Mark a dispatched step as `uncertain`: its effect may have happened and
  its result is not known. `attrs`: `:fence` (the turn's, required) and
  `:generation` (the step's, required), so a superseded runner or a stale
  generation marks nothing. Answers `{:error, :not_dispatched}` for a
  step in any other state. Event `step.uncertain`.
  """
  @spec mark_step_uncertain(Cyfr.Actor.t(), String.t(), String.t() | nil, map()) ::
          {:ok, TurnStep.t()} | {:error, term()}
  def mark_step_uncertain(%Cyfr.Actor{athanor_id: athanor_id}, step_id, reason, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.mark_step_uncertain", fn ->
      Arca.Repo.transaction(fn ->
        turn = own_step!(athanor_id, step_id, attrs)
        step = step!(athanor_id, step_id)
        mark_uncertain!(athanor_id, turn, step, Map.fetch!(attrs, :generation), reason)
        step!(athanor_id, step_id)
      end)
    end)
  end

  def mark_step_uncertain(%Cyfr.Actor{}, _step_id, _reason, _attrs), do: {:error, :no_athanor}

  # A dispatched step no runner will answer, by `TurnStep.unresolved/1`.
  # A closed call with no result row reads to the model as an unknown
  # outcome (`Aqua.Loop.Request`).
  # arca:db-raise-ok inside the caller's transaction
  defp settle_unresolved!(actor, athanor_id, %Turn{} = turn, %TurnStep{} = step, reason) do
    case TurnStep.unresolved(step) do
      :uncertain ->
        mark_uncertain!(athanor_id, turn, step, step.generation, reason)

      :unknown ->
        close_step!(actor, athanor_id, turn, step, "uncertain", %{error: reason})

      _unanswered_or_replay ->
        close_step!(actor, athanor_id, turn, step, "error", %{error: reason})
    end
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
  @spec skip_steps(Cyfr.Actor.t(), String.t(), String.t(), map()) ::
          {:ok, [TurnStep.t()]} | {:error, term()}
  def skip_steps(actor, turn_id, reason, attrs \\ %{})

  def skip_steps(%Cyfr.Actor{athanor_id: athanor_id} = actor, turn_id, reason, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(reason) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.skip_steps", fn ->
      with_seq_retry(fn ->
        Arca.Repo.transaction(fn ->
          turn = own!(athanor_id, turn_id, attrs)
          skip_proposed!(actor, athanor_id, turn, reason)
        end)
      end)
    end)
  end

  def skip_steps(%Cyfr.Actor{}, _turn_id, _reason, _attrs), do: {:error, :no_athanor}

  # arca:db-raise-ok inside the caller's transaction
  defp skip_proposed!(actor, athanor_id, %Turn{} = turn, reason) do
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
        close_step!(actor, athanor_id, turn, step, "skipped", %{
          result: %{content: reason, payload: %{"skipped" => true}}
        })

      closed
    end)
  end

  @doc """
  Rewrite a step's bookkeeping (`:excluded`, `:request_digest`, `:error`,
  `:authority_digest`) under `:fence`. Answers the rows written.
  """
  @spec update_step(Cyfr.Actor.t(), String.t(), map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def update_step(%Cyfr.Actor{athanor_id: athanor_id}, step_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.update_step", fn ->
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

  def update_step(%Cyfr.Actor{}, _step_id, _attrs), do: {:error, :no_athanor}

  @doc """
  The step barrier, run inside admission's transaction: bind the child
  execution to its step while the step is dispatched, on this generation,
  not cancel-requested, and the child id is the one the step pre-minted.
  Answers the rows bound — 0 when admission must abort.
  """
  @spec bind_child!(Cyfr.Actor.t(), String.t(), non_neg_integer(), String.t()) ::
          non_neg_integer()
  # arca:db-raise-ok inside the caller's transaction
  def bind_child!(%Cyfr.Actor{athanor_id: athanor_id}, step_id, generation, execution_id)
      when is_binary(athanor_id) and athanor_id != "" do
    {count, _} =
      from(s in TurnStep,
        where: s.athanor_id == ^athanor_id and s.id == ^step_id,
        where: s.generation == ^generation and s.dispatch_state == "dispatched",
        where: is_nil(s.cancel_requested_at) and s.child_execution_id == ^execution_id
      )
      |> Arca.Repo.update_all(set: [execution_id: execution_id])

    count
  end

  def bind_child!(%Cyfr.Actor{}, _step_id, _generation, _execution_id),
    do: Arca.QueryHelpers.no_athanor!("Arca.TurnStorage.bind_child!/4")

  @doc """
  Open the next generation of a step for a replay-safe re-dispatch: the
  old generation is cancel-marked so its late admission is refused, and
  the step returns to `proposed` with `generation + 1` and a fresh child
  execution id. `attrs`: `:child_execution_id`, `:fence`. Answers the step.
  """
  @spec next_generation(Cyfr.Actor.t(), String.t(), map()) ::
          {:ok, TurnStep.t()} | {:error, term()}
  def next_generation(%Cyfr.Actor{athanor_id: athanor_id}, step_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.next_generation", fn ->
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

  def next_generation(%Cyfr.Actor{}, _step_id, _attrs), do: {:error, :no_athanor}

  # ---------------------------------------------------------------------------
  # Approvals
  # ---------------------------------------------------------------------------

  @doc """
  Open an approval for a proposed step: the `approvals` row, the card
  message row that references it, and the step's `approval_id`, in one
  transaction. `attrs`: `:proposal_digest` (required: the digest the card
  is consumed by), `:expires_at`, `:scope`, `:card` (`%{content, payload}`
  — the payload the console card reads), `:fence`. Answers
  `{:ok, %{approval: row, card: row}}`, or `{:error, :proposal_digest_required}`.
  """
  @spec open_approval(Cyfr.Actor.t(), String.t(), map()) ::
          {:ok, %{approval: Approval.t(), card: Message.t()}} | {:error, term()}
  def open_approval(%Cyfr.Actor{athanor_id: athanor_id} = actor, step_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.open_approval", fn ->
      with_seq_retry(fn ->
        Arca.Repo.transaction(fn ->
          digest = Map.get(attrs, :proposal_digest)

          unless is_binary(digest) and digest != "",
            do: Arca.Repo.rollback(:proposal_digest_required)

          turn = own_step!(athanor_id, step_id, attrs)
          step = step!(athanor_id, step_id)
          thread = thread!(athanor_id, turn.thread_id)
          card = Map.get(attrs, :card, %{})
          approval_id = Map.get(attrs, :id) || Cyfr.UUID7.generate_id("apr")
          now = DateTime.utc_now()

          card_row =
            Arca.ThreadStorage.insert_message!(actor, thread, %{
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
              proposal_digest: digest,
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

  def open_approval(%Cyfr.Actor{}, _step_id, _attrs), do: {:error, :no_athanor}

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
  @spec resolve_approval(Cyfr.Actor.t(), String.t(), String.t(), map()) ::
          {:ok, %{approval: Approval.t(), step: TurnStep.t(), card: Message.t()}}
          | {:error, term()}
  def resolve_approval(%Cyfr.Actor{athanor_id: athanor_id} = actor, approval_id, decision, attrs)
      when is_binary(athanor_id) and athanor_id != "" and decision in @decisions and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.resolve_approval", fn ->
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
            close_step!(actor, athanor_id, turn, step, "denied", %{
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

  def resolve_approval(%Cyfr.Actor{}, _approval_id, _decision, _attrs), do: {:error, :no_athanor}

  # ---------------------------------------------------------------------------
  # Clones
  # ---------------------------------------------------------------------------

  @doc """
  Open a clone turn under `parent_turn_id`: its own `turns` row sharing
  the parent's root execution and attempt, the `clone` step in the
  parent (dispatched), and the task as the clone's first row. `attrs`:
  `:role` (the agent), `:task`, `:model`, `:step_id` (an existing
  clone step to bind, else one is recorded), `:fence`, and the clone's
  pins — `:profile_id`, `:consent_id`, `:agent_revision_digest`,
  `:agent_capability_digest` — written with the row so the clone runs
  the bytes that were checked. Answers `{:ok, %{turn, step, task: row}}`.
  """
  @spec open_clone_turn(Cyfr.Actor.t(), String.t(), map()) ::
          {:ok, %{turn: Turn.t(), step: TurnStep.t(), task: Message.t()}} | {:error, term()}
  def open_clone_turn(%Cyfr.Actor{athanor_id: athanor_id} = actor, parent_turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.open_clone_turn", fn ->
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
                agent: role,
                requested_by: parent.requested_by,
                model: Map.get(attrs, :model),
                profile_id: Map.get(attrs, :profile_id),
                consent_id: Map.get(attrs, :consent_id),
                agent_revision_digest: Map.get(attrs, :agent_revision_digest),
                agent_capability_digest: Map.get(attrs, :agent_capability_digest),
                fence: 1,
                runner_id: Cyfr.Boot.id(),
                status: "running",
                accepted_at: now,
                window_upto_seq: 0
              })
            )

          task =
            Arca.ThreadStorage.insert_message!(actor, thread, %{
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

  def open_clone_turn(%Cyfr.Actor{}, _parent_turn_id, _attrs), do: {:error, :no_athanor}

  @doc "The open clone turns under `turn_id`, oldest first."
  @spec open_clones(Cyfr.Actor.t(), String.t()) :: {:ok, [Turn.t()]} | {:error, term()}
  def open_clones(%Cyfr.Actor{athanor_id: athanor_id}, turn_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.open_clones", fn ->
      {:ok,
       Arca.Repo.all(
         from(t in Turn,
           where: t.athanor_id == ^athanor_id and t.parent_turn_id == ^turn_id,
           where: t.status in ^@open,
           order_by: [asc: t.accepted_at, asc: t.id]
         )
       )}
    end)
  end

  def open_clones(%Cyfr.Actor{}, _turn_id), do: {:error, :no_athanor}

  @doc "End a clone turn as `status` (`completed | failed | cancelled | uncertain`)."
  @spec close_clone_turn(Cyfr.Actor.t(), String.t(), String.t(), map()) ::
          {:ok, Turn.t()} | {:error, term()}
  def close_clone_turn(actor, turn_id, status, attrs \\ %{})

  def close_clone_turn(%Cyfr.Actor{athanor_id: athanor_id}, turn_id, status, attrs)
      when is_binary(athanor_id) and athanor_id != "" and status in @terminal do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.close_clone_turn", fn ->
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

  def close_clone_turn(%Cyfr.Actor{}, _turn_id, _status, _attrs), do: {:error, :no_athanor}

  # ---------------------------------------------------------------------------
  # The consumption boundary
  # ---------------------------------------------------------------------------

  @doc """
  Move the turn's boundary past every human row attached to it that
  arrived while it worked, and answer those rows in `seq` order: the
  steer the loop drains before its next model request.
  """
  @spec drain_steer(Cyfr.Actor.t(), String.t(), map()) :: {:ok, [Message.t()]} | {:error, term()}
  def drain_steer(actor, turn_id, attrs \\ %{})

  def drain_steer(%Cyfr.Actor{athanor_id: athanor_id}, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.drain_steer", fn ->
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

  def drain_steer(%Cyfr.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  @doc "Whether a human row attached to the turn waits past its boundary."
  @spec steer_pending?(Cyfr.Actor.t(), String.t()) :: boolean() | {:error, term()}
  def steer_pending?(%Cyfr.Actor{athanor_id: athanor_id}, turn_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.steer_pending?", fn ->
      turn = turn!(athanor_id, turn_id)
      steer_rows(athanor_id, turn) != []
    end)
  end

  def steer_pending?(%Cyfr.Actor{}, _turn_id),
    do: Arca.QueryHelpers.no_athanor!("Arca.TurnStorage.steer_pending?/2")

  @doc """
  The rows a turn may read, in `seq` order: its own rows except undrained
  human steer, plus — behind its boundary — unattached rows and the rows
  of terminal, non-clone turns of the thread. A clone reads its
  own rows only. Rows attached to other open turns are never read.
  """
  @spec projection(Cyfr.Actor.t(), String.t()) :: {:ok, [Message.t()]} | {:error, term()}
  def projection(%Cyfr.Actor{athanor_id: athanor_id}, turn_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.projection", fn ->
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

  def projection(%Cyfr.Actor{}, _turn_id), do: {:error, :no_athanor}

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  @doc """
  The `tool_call` payloads of the steps a turn and its clone turns closed
  with an `ok` outcome, oldest first: what the turn wrote to, read from
  the rows.
  """
  @spec closed_calls(Cyfr.Actor.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def closed_calls(%Cyfr.Actor{athanor_id: athanor_id}, turn_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.closed_calls", fn ->
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

  def closed_calls(%Cyfr.Actor{}, _turn_id), do: {:error, :no_athanor}

  @doc "One turn of the athanor."
  @spec get(Cyfr.Actor.t(), String.t()) :: {:ok, Turn.t()} | {:error, term()}
  def get(%Cyfr.Actor{athanor_id: athanor_id}, turn_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.get", fn ->
      case Arca.Repo.one(from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn_id)) do
        nil -> {:error, :not_found}
        turn -> {:ok, turn}
      end
    end)
  end

  def get(%Cyfr.Actor{}, _turn_id), do: {:error, :no_athanor}

  @doc "The turn a message opened, if any."
  @spec turn_of_message(Cyfr.Actor.t(), String.t()) :: {:ok, Turn.t()} | {:error, term()}
  def turn_of_message(%Cyfr.Actor{athanor_id: athanor_id}, message_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.turn_of_message", fn ->
      case Arca.Repo.one(
             from(t in Turn, where: t.athanor_id == ^athanor_id and t.message_id == ^message_id)
           ) do
        nil -> {:error, :not_found}
        turn -> {:ok, turn}
      end
    end)
  end

  def turn_of_message(%Cyfr.Actor{}, _message_id), do: {:error, :no_athanor}

  @doc "The steps of a turn in `seq` order."
  @spec steps(Cyfr.Actor.t(), String.t()) :: {:ok, [TurnStep.t()]} | {:error, term()}
  def steps(%Cyfr.Actor{athanor_id: athanor_id}, turn_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.steps", fn ->
      {:ok,
       Arca.Repo.all(
         from(s in TurnStep,
           where: s.athanor_id == ^athanor_id and s.turn_id == ^turn_id,
           order_by: [asc: s.seq]
         )
       )}
    end)
  end

  def steps(%Cyfr.Actor{}, _turn_id), do: {:error, :no_athanor}

  @doc "One step of the athanor."
  @spec step(Cyfr.Actor.t(), String.t()) :: {:ok, TurnStep.t()} | {:error, term()}
  def step(%Cyfr.Actor{athanor_id: athanor_id}, step_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.step", fn ->
      case Arca.Repo.one(
             from(s in TurnStep, where: s.athanor_id == ^athanor_id and s.id == ^step_id)
           ) do
        nil -> {:error, :not_found}
        step -> {:ok, step}
      end
    end)
  end

  def step(%Cyfr.Actor{}, _step_id), do: {:error, :no_athanor}

  @doc "The open turns of a thread (accepted, running or paused), oldest first."
  @spec open_turns(Cyfr.Actor.t(), String.t()) :: {:ok, [Turn.t()]} | {:error, term()}
  def open_turns(%Cyfr.Actor{athanor_id: athanor_id}, thread_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.open_turns", fn ->
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

  def open_turns(%Cyfr.Actor{}, _thread_id), do: {:error, :no_athanor}

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
  @spec approval(Cyfr.Actor.t(), String.t()) :: {:ok, Approval.t()} | {:error, term()}
  def approval(%Cyfr.Actor{athanor_id: athanor_id}, approval_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.approval", fn ->
      case Arca.Repo.one(
             from(a in Approval, where: a.athanor_id == ^athanor_id and a.id == ^approval_id)
           ) do
        nil -> {:error, :not_found}
        approval -> {:ok, approval}
      end
    end)
  end

  def approval(%Cyfr.Actor{}, _approval_id), do: {:error, :no_athanor}

  @doc "The approval a card message references."
  @spec approval_by_message(Cyfr.Actor.t(), String.t()) :: {:ok, Approval.t()} | {:error, term()}
  def approval_by_message(%Cyfr.Actor{athanor_id: athanor_id}, message_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.approval_by_message", fn ->
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

  def approval_by_message(%Cyfr.Actor{}, _message_id), do: {:error, :no_athanor}

  @doc "The pending approvals of a turn, oldest first."
  @spec pending_approvals(Cyfr.Actor.t(), String.t()) :: {:ok, [Approval.t()]} | {:error, term()}
  def pending_approvals(%Cyfr.Actor{athanor_id: athanor_id}, turn_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.pending_approvals", fn ->
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

  def pending_approvals(%Cyfr.Actor{}, _turn_id), do: {:error, :no_athanor}

  @doc "The athanor's pending approvals whose `expires_at` passed."
  @spec expired_approvals(Cyfr.Actor.t(), DateTime.t()) ::
          {:ok, [Approval.t()]} | {:error, term()}
  def expired_approvals(%Cyfr.Actor{athanor_id: athanor_id}, %DateTime{} = now)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.expired_approvals", fn ->
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

  def expired_approvals(%Cyfr.Actor{}, _now), do: {:error, :no_athanor}

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
  defp close_step!(actor, athanor_id, turn, step, outcome, attrs) do
    from_states =
      if outcome in ["denied", "skipped"], do: ["dispatched", "proposed"], else: ["dispatched"]

    now = DateTime.utc_now()

    result =
      case Map.get(attrs, :result) do
        nil ->
          nil

        %{} = result ->
          thread = thread!(athanor_id, turn.thread_id)

          Arca.ThreadStorage.insert_message!(actor, thread, %{
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
    purpose = Map.get(attrs, :purpose, "chat")

    if purpose not in TurnStep.purposes(),
      do: Arca.Repo.rollback({:invalid_step_purpose, purpose})

    Arca.Repo.insert!(%TurnStep{
      id: Map.get(attrs, :id) || Cyfr.UUID7.generate_id("stp"),
      athanor_id: athanor_id,
      turn_id: turn.id,
      seq: seq,
      kind: kind,
      purpose: purpose,
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
    Arca.ExecutionEvents.append!(Cyfr.Actor.in_athanor(athanor_id), turn.root_execution_id, type,
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

  # The thread's claim, taken for a root turn that is starting. One
  # statement naming the turn and the consumed sequence the caller read,
  # so of two members starting a turn on one thread exactly one write
  # matches; a claimant that reads no sequence of its own is held only to
  # the holder. A thread this turn already holds is answered, so a start
  # retried after a crash claims what it already had.
  #
  # Clone turns never hold the thread: the root they run under does.
  # arca:db-raise-ok inside the caller's transaction
  defp claim_thread!(_athanor_id, %Turn{parent_turn_id: parent}, _attrs) when is_binary(parent),
    do: :ok

  defp claim_thread!(athanor_id, %Turn{} = turn, attrs) do
    thread = thread!(athanor_id, turn.thread_id)
    expected = Map.get(attrs, :turn_seq) || thread.turn_seq || 0

    claimed =
      from(c in Thread,
        where: c.id == ^turn.thread_id and c.athanor_id == ^athanor_id,
        where: c.turn_seq == ^expected,
        where: is_nil(c.active_turn_id) or c.active_turn_id == ^turn.id
      )
      |> Arca.Repo.update_all(set: [active_turn_id: turn.id])

    case claimed do
      {1, _} ->
        :ok

      {0, _} ->
        case thread do
          %Thread{turn_seq: seq} when seq != expected -> Arca.Repo.rollback(:stale)
          %Thread{active_turn_id: held} -> Arca.Repo.rollback({:busy, held})
        end
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
  # the caller read is raised by one in the same write, so of two
  # transitions racing over one turn only the first lands; the fences of
  # the turn's open clones rise with it, so no clone loop writes past the
  # take. The turn row is locked before its clones', the order every
  # transaction that touches both follows.
  # arca:db-raise-ok inside the caller's transaction
  defp take!(athanor_id, turn_id, attrs) do
    fence = held_fence!(attrs)

    case from(t in Turn,
           where: t.athanor_id == ^athanor_id and t.id == ^turn_id and t.fence == ^fence
         )
         |> Arca.Repo.update_all(inc: [fence: 1]) do
      {1, _} ->
        from(t in Turn, where: t.id in subquery(open_clone_ids(athanor_id, turn_id)))
        |> Arca.Repo.update_all(inc: [fence: 1])

        turn!(athanor_id, turn_id)

      {0, _} ->
        Arca.Repo.rollback(:superseded)
    end
  end

  defp open_clone_ids(athanor_id, turn_id) do
    from(t in Turn,
      where: t.athanor_id == ^athanor_id and t.parent_turn_id == ^turn_id,
      where: t.status in ^@open,
      select: t.id
    )
  end

  defp held_fence!(attrs) do
    case Map.get(attrs, :fence) do
      fence when is_integer(fence) -> fence
      _ -> Arca.Repo.rollback(:fence_required)
    end
  end

  # A steer's turn, its row locked as the transaction's first write — the
  # order every runner-owned write follows (turn, then thread).
  # arca:db-raise-ok inside the caller's transaction
  defp hold_open_turn!(athanor_id, %Thread{id: thread_id}, turn_id) do
    held =
      from(t in Turn,
        where: t.athanor_id == ^athanor_id and t.id == ^turn_id and t.thread_id == ^thread_id,
        where: t.status in ^@open,
        update: [set: [status: t.status]]
      )
      |> Arca.Repo.update_all([])

    case held do
      {1, _} -> turn!(athanor_id, turn_id)
      {0, _} -> Arca.Repo.rollback(:turn_over)
    end
  end

  defp encode(nil), do: nil
  defp encode(value) when is_binary(value), do: value
  defp encode(value), do: Jason.encode!(value)

  defp reject_nil(map) when is_map(map) do
    map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
  end
end
