# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Tape do
  @moduledoc """
  The one persistence port of the runner and the loop: every row a turn
  writes — messages, turns, steps, approvals, events — goes through here,
  and nothing under `Aqua.Runner` or `Aqua.Loop` names a storage module.

  Each write is one storage transaction (`Arca.TurnStorage`), fenced on
  the turn's `fence`: a runner whose fence moved is refused
  `{:error, :superseded}`. The rows a person sees are broadcast on the
  thread's topic AFTER the transaction commits, in the vocabulary
  the console already reads (`{:thread, id, {:message, row}}`);
  approvals are also announced to the estate (`Sanctum.Notify`). A
  guest-planed context writes here unchanged: the tape is a narrow
  interface, not a plane, and the tenant is the context's.

  Pausing and resuming a turn are `Cyfr.Execution`'s
  (`Cyfr.Execution.pause_turn_root/3`, `resume_turn_root/3`): they move
  the rows with the root's slot and lease, which only the process holding
  them can do.

  ## The thread's claim

  Which turn may run at all is `threads.active_turn_id`, not a process on
  any member. `start_turn/3` takes it, `finish/4` and `suspend/3` give it
  up, `bump_recovery/2` and `recover/2` take it from a turn whose holder
  is not a live member, and `claim_holder/2` reads it. An approval pause
  keeps it.
  """

  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage
  alias Sanctum.Context

  # The rows `Arca.TurnStorage` and `Arca.ThreadStorage` answer, each a
  # plain map of the row's columns.
  @type turn :: %{required(:id) => String.t(), optional(atom()) => term()}
  @type step :: %{required(:id) => String.t(), optional(atom()) => term()}
  @type row :: %{required(:id) => String.t(), optional(atom()) => term()}
  @type approval :: %{required(:id) => String.t(), optional(atom()) => term()}

  @doc "Whether the turn has a terminal status in the durable lifecycle."
  @spec terminal?(turn()) :: boolean()
  def terminal?(%{status: status}), do: status in TurnStorage.terminal_statuses()

  @doc "How many automatic recoveries a turn gets before it ends `uncertain`."
  @spec recovery_cap() :: pos_integer()
  def recovery_cap, do: TurnStorage.recovery_cap()

  # ---------------------------------------------------------------------------
  # Acceptance
  # ---------------------------------------------------------------------------

  @doc """
  Accept a message atomically with the work it opens. `attrs`:
  `:message` (`:author`, `:content`, `:payload`, optional `:id`,
  `:client_id`), and one of `:turn` (`%{agent, requested_by,
  model, options}`) or `:steer_turn_id`, or neither for room content.

  A `client_id` this thread already accepted answers the existing
  acceptance as `replayed: true` when it is the same send — same actor,
  text, attachments, and the same work: the agent, model and room of the
  turn it opened, or the turn it steered — and `{:error, :client_id_reused}`
  when it is not. A message `id` already
  taken is answered the same way through its `client_id`, and refused
  `{:error, :message_id_reused}` without one or under another's.
  """
  @spec accept(Context.t(), String.t(), map()) ::
          {:ok, %{message: row(), turn: turn() | nil, replayed: boolean()}} | {:error, term()}
  def accept(%Context{} = ctx, thread_id, attrs) when is_map(attrs) do
    case TurnStorage.accept_message(Sanctum.Context.actor(ctx), thread_id, attrs) do
      {:ok, %{message: message, turn: turn}} ->
        broadcast(ctx, thread_id, {:message, message})
        {:ok, %{message: message, turn: turn, replayed: false}}

      {:error, reason} when reason in [:duplicate_client_id, :message_id_reused] ->
        replay(ctx, thread_id, attrs, reason)

      other ->
        other
    end
  end

  # The identity offered again — by client id, or by a message id already
  # taken — answers what was accepted when it is the same send; the
  # client id is what names the accepted row, so an id offered without one
  # is another send's.
  defp replay(ctx, thread_id, attrs, reason) do
    case get_in(attrs, [:message, :client_id]) do
      client_id when is_binary(client_id) ->
        case TurnStorage.accepted(Sanctum.Context.actor(ctx), thread_id, client_id) do
          {:ok, %{message: message, turn: turn}} ->
            if same_send?(message, turn, attrs),
              do: {:ok, %{message: message, turn: turn, replayed: true}},
              else: {:error, reused(reason)}

          {:error, :not_found} ->
            {:error, reused(reason)}

          {:error, _} = error ->
            error
        end

      _ ->
        {:error, reused(reason)}
    end
  end

  defp reused(:duplicate_client_id), do: :client_id_reused
  defp reused(:message_id_reused), do: :message_id_reused

  @doc """
  The acceptance a `client_id` already produced in this thread:
  its message and, when the row opened or steered a turn, that turn.
  `{:error, :not_found}` for a `client_id` never accepted.
  """
  @spec accepted(Context.t(), String.t(), String.t()) ::
          {:ok, %{message: row(), turn: turn() | nil}} | {:error, term()}
  def accepted(%Context{} = ctx, thread_id, client_id) when is_binary(client_id),
    do: TurnStorage.accepted(Sanctum.Context.actor(ctx), thread_id, client_id)

  @doc "Append one row outside a turn's step machinery (a system note, a compaction, an aborted mark)."
  @spec append(Context.t(), String.t(), map()) :: {:ok, row()} | {:error, term()}
  def append(%Context{} = ctx, thread_id, attrs) when is_map(attrs) do
    with {:ok, row} <- Threads.append(Sanctum.Context.actor(ctx), thread_id, attrs) do
      broadcast(ctx, thread_id, {:message, row})
      {:ok, row}
    end
  end

  @doc "The `turn_aborted` system row: tools may have partially executed."
  @spec append_aborted(Context.t(), turn(), String.t()) :: {:ok, row()} | {:error, term()}
  def append_aborted(%Context{} = ctx, turn, reason) when is_binary(reason) do
    turn_row(ctx, turn, %{
      author: Cyfr.Author.system(),
      kind: "turn_aborted",
      content: reason
    })
  end

  # A row the turn owns, written inside its fence. Both of these change what
  # the next request reads, so a runner whose fence has moved must not be
  # able to add one — the generic `append/3` asks the thread and would
  # have let a superseded loop rewrite its successor's projection.
  defp turn_row(%Context{} = ctx, turn, attrs) do
    attrs =
      attrs
      |> Map.put(:execution_id, turn.root_execution_id)
      |> Map.put(:fence, turn.fence)

    with {:ok, row} <- TurnStorage.append_turn_row(Sanctum.Context.actor(ctx), turn.id, attrs) do
      broadcast(ctx, turn.thread_id, {:message, row})
      {:ok, row}
    end
  end

  @doc """
  The compaction row: `first_kept_seq` (inclusive), `summarized_through_seq`
  and the summary the projection reads in place of the rows before it.
  """
  @spec append_compaction(Context.t(), turn(), map()) :: {:ok, row()} | {:error, term()}
  def append_compaction(%Context{} = ctx, turn, attrs) when is_map(attrs) do
    turn_row(ctx, turn, %{
      author: Cyfr.Author.system(),
      kind: "compaction",
      content: Map.get(attrs, :summary, ""),
      payload: %{
        "first_kept_seq" => Map.fetch!(attrs, :first_kept_seq),
        "summarized_through_seq" => Map.fetch!(attrs, :summarized_through_seq),
        "step_id" => Map.get(attrs, :step_id)
      }
    })
  end

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Start an accepted turn with its root, attempt, budget and pins
  (`TurnStorage.start/3`), taking the thread's claim with it.

  The claim names the consumed sequence read here, a moment before the
  statement that compares it: that read and that write are the
  compare-and-set which decides, between two members planning from the
  same thread, whose turn runs. A sequence that moved under the read is
  not a refusal — a peer accepted the next message, which changes nothing
  about this turn's right to run — so the thread is read again, a bounded
  number of times. A thread another turn holds is
  `{:error, {:busy, turn_id}}` and is the caller's to queue behind.
  """
  @spec start_turn(Context.t(), turn(), map()) :: {:ok, turn()} | {:error, term()}
  def start_turn(%Context{} = ctx, turn, attrs) when is_map(attrs),
    do: start_turn(ctx, turn, attrs, 3)

  defp start_turn(_ctx, _turn, _attrs, 0), do: {:error, :stale}

  defp start_turn(%Context{} = ctx, turn, attrs, tries) do
    actor = Sanctum.Context.actor(ctx)

    attrs =
      case Threads.get(actor, turn.thread_id) do
        {:ok, thread} -> Map.put(attrs, :turn_seq, thread.turn_seq || 0)
        {:error, _} -> attrs
      end

    case TurnStorage.start(actor, turn.id, Map.put_new(attrs, :fence, turn.fence)) do
      {:error, :stale} -> start_turn(ctx, turn, Map.delete(attrs, :turn_seq), tries - 1)
      other -> other
    end
  end

  @doc """
  Set a running or paused turn down, its rows kept and the thread's claim
  given up, so any member may pick it up (`TurnStorage.suspend/3`). The
  caller stops the turn's runtime; this is the durable half.
  """
  @spec suspend(Context.t(), turn(), String.t() | nil) :: {:ok, turn()} | {:error, term()}
  def suspend(%Context{} = ctx, turn, reason \\ nil) do
    with {:ok, suspended} <-
           TurnStorage.suspend(Sanctum.Context.actor(ctx), turn.id, %{
             fence: turn.fence,
             reason: reason
           }) do
      broadcast(ctx, turn.thread_id, {:turn_suspended, turn.id})
      {:ok, suspended}
    end
  end

  @doc """
  Take the thread's claim for an open turn no live member runs and count
  the recovery, in one transaction (`TurnStorage.recover/3`), from the
  fence `turn` was read with. Refused past the cap, and `{:error, :busy}`
  for a thread a live peer holds.
  """
  @spec recover(Context.t(), turn()) :: {:ok, turn()} | {:error, term()}
  def recover(%Context{} = ctx, turn),
    do:
      TurnStorage.recover(
        Sanctum.Context.actor(ctx),
        turn.id,
        standing(%{fence: turn.fence}, :current)
      )

  @doc """
  Which turn holds the thread, and whether a live peer runs it
  (`Arca.ThreadStorage.claim_holder/2`) — the row's answer to "is anybody
  working this thread", which a local registry cannot give.
  """
  @spec claim_holder(Context.t(), String.t()) ::
          {:ok, %{turn_id: String.t() | nil, runner_id: String.t() | nil, live_peer?: boolean()}}
          | {:error, term()}
  def claim_holder(%Context{} = ctx, thread_id),
    do: Threads.claim_holder(Sanctum.Context.actor(ctx), thread_id)

  @doc """
  End a turn: the one terminal transaction (`TurnStorage.finish/4`),
  under the grant its root's attempt stores. A completion needs that
  grant to stand; a turn that fails, is cancelled or ends uncertain
  retires work and needs only the stored stamp.
  """
  @spec finish(Context.t(), turn(), String.t(), map()) :: {:ok, turn()} | {:error, term()}
  def finish(%Context{} = ctx, turn, status, attrs \\ %{}) do
    with {:ok, finished} <-
           TurnStorage.finish(
             Sanctum.Context.actor(ctx),
             turn.id,
             status,
             attrs
             |> Map.put_new(:fence, turn.fence)
             |> standing(if(status == "completed", do: :current, else: :retiring))
           ) do
      broadcast(ctx, turn.thread_id, {:turn_finished})
      {:ok, finished}
    end
  end

  @doc """
  Take over a turn another runner lost: the successor attempt, the new
  fence and the recovery count (`TurnStorage.takeover/3`), from the fence
  `turn` was read with. Refused past the cap.
  """
  @spec bump_recovery(Context.t(), turn()) :: {:ok, turn()} | {:error, term()}
  def bump_recovery(%Context{} = ctx, turn),
    do:
      TurnStorage.takeover(
        Sanctum.Context.actor(ctx),
        turn.id,
        standing(%{fence: turn.fence}, :current)
      )

  # The grant a write on the turn's root attempt runs under: the stamp that
  # attempt stores (`TurnStorage`'s "The root's grant"), which must still
  # stand, or — for a turn that retires its work — need only be carried.
  defp standing(attrs, :current),
    do: Map.merge(attrs, %{grant: :stored, verify: &Sanctum.ExecutionStanding.verify/1})

  defp standing(attrs, :retiring),
    do: Map.merge(attrs, %{grant: :stored, verify: &Sanctum.ExecutionStanding.stamp_only/1})

  @doc "Pin the exact catalyst release the turn runs on (`TurnStorage.pin_catalyst/4`)."
  @spec pin_catalyst(Context.t(), turn(), String.t()) :: {:ok, turn()} | {:error, term()}
  def pin_catalyst(%Context{} = ctx, turn, catalyst_ref),
    do:
      TurnStorage.pin_catalyst(Sanctum.Context.actor(ctx), turn.id, catalyst_ref, %{
        fence: turn.fence
      })

  @doc "Renew the fence and cancel-mark the dispatched steps, before the loop is stopped."
  @spec supersede(Context.t(), turn()) :: {:ok, turn()} | {:error, term()}
  def supersede(%Context{} = ctx, turn),
    do: TurnStorage.supersede(Sanctum.Context.actor(ctx), turn.id, %{fence: turn.fence})

  # ---------------------------------------------------------------------------
  # Steps
  # ---------------------------------------------------------------------------

  @doc "Record the model call the loop is about to make, before it is made."
  @spec record_model_intent(Context.t(), turn(), map()) :: {:ok, step()} | {:error, term()}
  def record_model_intent(%Context{} = ctx, turn, attrs \\ %{}) do
    TurnStorage.put_step(
      Sanctum.Context.actor(ctx),
      turn.id,
      attrs |> Map.put(:kind, "model") |> Map.put_new(:fence, turn.fence)
    )
  end

  @doc """
  Persist a model response before any of its calls runs: the reply and
  the tool calls as rows, every call as a proposed step
  (`TurnStorage.record_response/4`). The rows are broadcast after commit.
  """
  @spec record_response(Context.t(), turn(), step(), map()) ::
          {:ok, %{text: row() | nil, calls: [map()]}} | {:error, term()}
  def record_response(%Context{} = ctx, turn, model_step, response) when is_map(response) do
    with {:ok, %{text: text, calls: calls} = recorded} <-
           TurnStorage.record_response(
             Sanctum.Context.actor(ctx),
             turn.id,
             model_step.id,
             Map.put_new(response, :fence, turn.fence)
           ) do
      if text, do: broadcast(ctx, turn.thread_id, {:message, text})
      Enum.each(calls, &broadcast(ctx, turn.thread_id, {:message, &1.message}))
      {:ok, recorded}
    end
  end

  @doc "Flip a proposed step to dispatched, in its own commit."
  @spec mark_dispatched(Context.t(), turn(), step()) :: {:ok, step()} | {:error, term()}
  def mark_dispatched(%Context{} = ctx, turn, step),
    do: TurnStorage.dispatch_step(Sanctum.Context.actor(ctx), step.id, %{fence: turn.fence})

  @doc "Close a step with its result row, outcome and event, in one transaction."
  @spec close_step(Context.t(), turn(), step(), String.t(), map()) ::
          {:ok, %{step: step(), result: row() | nil}} | {:error, term()}
  def close_step(%Context{} = ctx, turn, step, outcome, attrs \\ %{}) do
    with {:ok, %{result: result} = closed} <-
           TurnStorage.close_step(
             Sanctum.Context.actor(ctx),
             step.id,
             outcome,
             Map.put_new(attrs, :fence, turn.fence)
           ) do
      if result, do: broadcast(ctx, turn.thread_id, {:message, result})
      {:ok, closed}
    end
  end

  @doc """
  Mark a dispatched step whose effect cannot be known, under the turn's
  fence and the step's generation: a clone's own step, or a sibling a
  root turn's pause already covers.
  """
  @spec mark_uncertain(Context.t(), turn(), step(), String.t() | nil) ::
          {:ok, step()} | {:error, term()}
  def mark_uncertain(%Context{} = ctx, turn, step, reason \\ nil),
    do:
      TurnStorage.mark_step_uncertain(Sanctum.Context.actor(ctx), step.id, reason, %{
        fence: turn.fence,
        generation: step.generation
      })

  @doc """
  Stop a root turn on a call whose outcome is unknown: the durable
  boundary of D6, in one transaction (`TurnStorage.pause_uncertain/3`).
  `attrs`: `:step_id`, `:generation`, `:reason`, `:content`. The aborted
  row is broadcast after commit.
  """
  @spec pause_uncertain(Context.t(), turn(), map()) ::
          {:ok, %{turn: turn(), aborted: row()}} | {:error, term()}
  def pause_uncertain(%Context{} = ctx, turn, attrs) when is_map(attrs) do
    with {:ok, %{aborted: aborted} = paused} <-
           TurnStorage.pause_uncertain(
             Sanctum.Context.actor(ctx),
             turn.id,
             Map.put_new(attrs, :fence, turn.fence)
           ) do
      broadcast(ctx, turn.thread_id, {:message, aborted})
      {:ok, paused}
    end
  end

  @doc "Set down a running turn a dead runner left with an unacknowledged uncertainty (`TurnStorage.pause_recovered/3`)."
  @spec pause_recovered(Context.t(), turn(), String.t()) :: {:ok, turn()} | {:error, term()}
  def pause_recovered(%Context{} = ctx, turn, content) when is_binary(content),
    do:
      TurnStorage.pause_recovered(
        Sanctum.Context.actor(ctx),
        turn.id,
        standing(%{content: content, fence: turn.fence}, :current)
      )

  @doc "Whether the turn holds an uncertainty its sender has not acknowledged."
  @spec unacknowledged_episode?(Context.t(), turn()) :: boolean()
  def unacknowledged_episode?(%Context{} = ctx, turn),
    do: TurnStorage.unacknowledged_episode?(Sanctum.Context.actor(ctx), turn.id) == true

  @doc "Whether the turn is restricted to replay-safe reads: any of its steps is `uncertain`."
  @spec restricted?(Context.t(), turn()) :: boolean()
  def restricted?(%Context{} = ctx, turn),
    do: TurnStorage.restricted?(Sanctum.Context.actor(ctx), turn.id) == true

  @doc "Close every unstarted step as skipped and invalidate their cards."
  @spec skip_steps(Context.t(), turn(), String.t()) :: {:ok, [step()]} | {:error, term()}
  def skip_steps(%Context{} = ctx, turn, reason) do
    with {:ok, steps} <-
           TurnStorage.skip_steps(Sanctum.Context.actor(ctx), turn.id, reason, %{
             fence: turn.fence
           }) do
      Enum.each(steps, fn step ->
        with {:ok, row} <- Threads.get_message(Sanctum.Context.actor(ctx), step.result_message_id),
             do: broadcast(ctx, turn.thread_id, {:message, row})
      end)

      {:ok, steps}
    end
  end

  @doc "Open the next generation of a replay-safe step with a fresh child id."
  @spec next_generation(Context.t(), turn(), step(), String.t()) ::
          {:ok, step()} | {:error, term()}
  def next_generation(%Context{} = ctx, turn, step, child_execution_id),
    do:
      TurnStorage.next_generation(Sanctum.Context.actor(ctx), step.id, %{
        child_execution_id: child_execution_id,
        fence: turn.fence
      })

  @doc "Record what a model request left out (`[\"room_excerpt\"]`) or its digest."
  @spec mark_excluded(Context.t(), turn(), step(), map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def mark_excluded(%Context{} = ctx, turn, step, attrs),
    do:
      TurnStorage.update_step(
        Sanctum.Context.actor(ctx),
        step.id,
        Map.put(attrs, :fence, turn.fence)
      )

  # ---------------------------------------------------------------------------
  # Approvals
  # ---------------------------------------------------------------------------

  @doc "Open a card for a proposed step; the estate is told after commit."
  @spec open_approval(Context.t(), turn(), step(), map()) ::
          {:ok, %{approval: approval(), card: row()}} | {:error, term()}
  def open_approval(%Context{} = ctx, turn, step, attrs) when is_map(attrs) do
    with {:ok, %{card: card, approval: approval} = opened} <-
           TurnStorage.open_approval(
             Sanctum.Context.actor(ctx),
             step.id,
             Map.put_new(attrs, :fence, turn.fence)
           ) do
      broadcast(ctx, turn.thread_id, {:message, card})

      Sanctum.Notify.broadcast(Context.athanor!(ctx), :approval_pending, %{
        thread_id: turn.thread_id,
        message_id: card.id,
        approval_id: approval.id
      })

      {:ok, opened}
    end
  end

  @doc "Consume a pending approval with the decision and its consequences, in one transaction."
  @spec resolve_approval(Context.t(), turn(), String.t(), String.t(), map()) ::
          {:ok, %{approval: approval(), step: step(), card: row()}} | {:error, term()}
  def resolve_approval(%Context{} = ctx, turn, approval_id, decision, attrs) when is_map(attrs) do
    with {:ok, %{card: card, step: step} = resolved} <-
           TurnStorage.resolve_approval(
             Sanctum.Context.actor(ctx),
             approval_id,
             decision,
             Map.put_new(attrs, :fence, turn.fence)
           ) do
      broadcast(ctx, turn.thread_id, {:message, card})

      if step.result_message_id do
        with {:ok, row} <- Threads.get_message(Sanctum.Context.actor(ctx), step.result_message_id),
             do: broadcast(ctx, turn.thread_id, {:message, row})
      end

      Sanctum.Notify.broadcast(Context.athanor!(ctx), :approval_resolved, %{
        thread_id: turn.thread_id,
        message_id: card.id,
        approval_id: approval_id,
        decision: decision
      })

      # The runner holding the turn learns the decision from the topic,
      # after the commit like every row.
      broadcast(ctx, turn.thread_id, {
        :approval_resolved,
        %{
          approval_id: approval_id,
          turn_id: turn.id,
          step_id: step.id,
          decision: decision,
          resolution_kind: Map.get(resolved.approval, :resolution_kind)
        }
      })

      {:ok, resolved}
    end
  end

  # ---------------------------------------------------------------------------
  # Clones
  # ---------------------------------------------------------------------------

  @doc "Open a clone turn under a running parent; the task row is broadcast."
  @spec open_clone_turn(Context.t(), turn(), map()) ::
          {:ok, %{turn: turn(), step: step(), task: row()}} | {:error, term()}
  def open_clone_turn(%Context{} = ctx, parent, attrs) when is_map(attrs) do
    with {:ok, %{task: task} = opened} <-
           TurnStorage.open_clone_turn(
             Sanctum.Context.actor(ctx),
             parent.id,
             Map.put_new(attrs, :fence, parent.fence)
           ) do
      broadcast(ctx, parent.thread_id, {:message, task})
      {:ok, opened}
    end
  end

  @doc "The open clone turns under `turn`, oldest first."
  @spec open_clones(Context.t(), turn()) :: {:ok, [turn()]} | {:error, term()}
  def open_clones(%Context{} = ctx, turn),
    do: TurnStorage.open_clones(Sanctum.Context.actor(ctx), turn.id)

  @doc "End a clone turn."
  @spec close_clone_turn(Context.t(), turn(), String.t(), map()) ::
          {:ok, turn()} | {:error, term()}
  def close_clone_turn(%Context{} = ctx, clone, status, attrs \\ %{}),
    do:
      TurnStorage.close_clone_turn(
        Sanctum.Context.actor(ctx),
        clone.id,
        status,
        Map.put_new(attrs, :fence, clone.fence)
      )

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  @doc "The rows a turn may read now, in `seq` order (`TurnStorage.projection/2`)."
  @spec projection(Context.t(), turn()) :: {:ok, [row()]} | {:error, term()}
  def projection(%Context{} = ctx, turn),
    do: TurnStorage.projection(Sanctum.Context.actor(ctx), turn.id)

  @doc "Drain the steer rows past the turn's boundary, moving the boundary."
  @spec drain_steer(Context.t(), turn()) :: {:ok, [row()]} | {:error, term()}
  def drain_steer(%Context{} = ctx, turn),
    do: TurnStorage.drain_steer(Sanctum.Context.actor(ctx), turn.id, %{fence: turn.fence})

  @doc "Whether a steer row waits past the turn's boundary."
  @spec steer_pending?(Context.t(), turn()) :: boolean()
  def steer_pending?(%Context{} = ctx, turn),
    do: TurnStorage.steer_pending?(Sanctum.Context.actor(ctx), turn.id) == true

  @doc "One turn, re-read."
  @spec turn(Context.t(), String.t()) :: {:ok, turn()} | {:error, term()}
  def turn(%Context{} = ctx, turn_id), do: TurnStorage.get(Sanctum.Context.actor(ctx), turn_id)

  @doc "The turn a message opened."
  @spec turn_of_message(Context.t(), String.t()) :: {:ok, turn()} | {:error, term()}
  def turn_of_message(%Context{} = ctx, message_id),
    do: TurnStorage.turn_of_message(Sanctum.Context.actor(ctx), message_id)

  @doc "A turn's steps in order."
  @spec steps(Context.t(), turn()) :: {:ok, [step()]} | {:error, term()}
  def steps(%Context{} = ctx, turn), do: TurnStorage.steps(Sanctum.Context.actor(ctx), turn.id)

  @doc "One step, re-read."
  @spec step(Context.t(), String.t()) :: {:ok, step()} | {:error, term()}
  def step(%Context{} = ctx, step_id), do: TurnStorage.step(Sanctum.Context.actor(ctx), step_id)

  @doc "The open turns of a thread, oldest first."
  @spec open_turns(Context.t(), String.t()) :: {:ok, [turn()]} | {:error, term()}
  def open_turns(%Context{} = ctx, thread_id),
    do: TurnStorage.open_turns(Sanctum.Context.actor(ctx), thread_id)

  @doc "Every thread with an open root turn, across tenants — the boot's recovery scan."
  @spec with_open_turns() :: [{String.t(), String.t()}]
  def with_open_turns, do: TurnStorage.with_open_turns()

  @doc "One approval."
  @spec approval(Context.t(), String.t()) :: {:ok, approval()} | {:error, term()}
  def approval(%Context{} = ctx, approval_id),
    do: TurnStorage.approval(Sanctum.Context.actor(ctx), approval_id)

  @doc "The approval a card references."
  @spec approval_by_message(Context.t(), String.t()) :: {:ok, approval()} | {:error, term()}
  def approval_by_message(%Context{} = ctx, message_id),
    do: TurnStorage.approval_by_message(Sanctum.Context.actor(ctx), message_id)

  @doc "A turn's pending approvals."
  @spec pending_approvals(Context.t(), turn()) :: {:ok, [approval()]} | {:error, term()}
  def pending_approvals(%Context{} = ctx, turn),
    do: TurnStorage.pending_approvals(Sanctum.Context.actor(ctx), turn.id)

  @doc "The estate's pending approvals past their expiry."
  @spec expired_approvals(Context.t()) :: {:ok, [approval()]} | {:error, term()}
  def expired_approvals(%Context{} = ctx),
    do: TurnStorage.expired_approvals(Sanctum.Context.actor(ctx), DateTime.utc_now())

  @doc "The agent bytes a turn pinned, by their digest."
  @spec agent_revision(Context.t(), turn()) :: {:ok, binary()} | {:error, term()}
  def agent_revision(%Context{} = ctx, %{agent_revision_digest: digest}) when is_binary(digest),
    do: Arca.AgentRevisions.get(Context.actor(ctx), digest)

  def agent_revision(_ctx, _turn), do: {:error, :no_revision}

  @doc """
  Announce an ephemeral console event on the thread's topic — a
  delta, the tool activity, the usage, the sender's intents — without a
  row.
  """
  @spec announce(Context.t(), String.t(), term()) :: :ok
  def announce(%Context{} = ctx, thread_id, event),
    do: broadcast(ctx, thread_id, event)

  @doc "The `tool_call` payloads of the calls a turn and its clones closed."
  @spec closed_calls(Context.t(), turn()) :: {:ok, [map()]} | {:error, term()}
  def closed_calls(%Context{} = ctx, turn),
    do: TurnStorage.closed_calls(Sanctum.Context.actor(ctx), turn.id)

  @doc "The decoded `payload` of a message row."
  @spec payload(row()) :: map()
  def payload(row), do: Threads.payload(row)

  @doc "One message row of the tenant."
  @spec message(Context.t(), String.t()) :: {:ok, row()} | {:error, term()}
  def message(%Context{} = ctx, message_id),
    do: Threads.get_message(Sanctum.Context.actor(ctx), message_id)

  @doc "The thread a turn belongs to."
  @spec thread(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def thread(%Context{} = ctx, thread_id), do: Threads.get(Sanctum.Context.actor(ctx), thread_id)

  @doc "The newest rows of a thread, for a viewer."
  @spec latest_messages(Context.t(), String.t(), pos_integer()) ::
          [row()] | {:error, term()}
  def latest_messages(%Context{} = ctx, thread_id, n),
    do: Threads.latest_messages(Sanctum.Context.actor(ctx), thread_id, n)

  @doc "The topic a thread's rows are broadcast on."
  @spec topic(Context.t(), String.t()) :: String.t()
  def topic(%Context{} = ctx, thread_id),
    do: Cyfr.Bus.thread(thread_id, Context.athanor!(ctx))

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  # Durable rows reach viewers only after their transaction committed.
  defp broadcast(ctx, thread_id, event) do
    Phoenix.PubSub.broadcast(
      Emissary.PubSub,
      topic(ctx, thread_id),
      {:thread, thread_id, event}
    )

    :ok
  end

  # The same send, as far as the rows can tell: actor, text, attachments,
  # and the work it asked for.
  defp same_send?(message, turn, attrs) do
    wanted = Map.get(attrs, :message, %{})
    wanted_turn = Map.get(attrs, :turn)
    payload = Threads.payload(message)

    message.author == Map.get(wanted, :author) and
      message.content == (Map.get(wanted, :content) || "") and
      Map.get(payload, "attachments") == attachments_of(Map.get(wanted, :payload)) and
      same_work?(turn, wanted_turn, Map.get(attrs, :steer_turn_id))
  end

  defp attachments_of(nil), do: nil

  defp attachments_of(payload) when is_map(payload),
    do: payload[:attachments] || payload["attachments"]

  defp same_work?(nil, nil, nil), do: true

  defp same_work?(%{id: id}, nil, steer_id) when is_binary(steer_id), do: id == steer_id

  defp same_work?(%{message_id: message_id} = turn, %{} = wanted, nil)
       when is_binary(message_id) do
    turn.agent == Map.get(wanted, :agent) and
      turn.model == Map.get(wanted, :model) and
      turn.options == encode(Map.get(wanted, :options))
  end

  defp same_work?(_turn, _wanted, _steer), do: false

  defp encode(nil), do: nil
  defp encode(value), do: Jason.encode!(value)
end
