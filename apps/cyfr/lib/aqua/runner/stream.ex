# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Runner.Stream do
  @moduledoc """
  A running turn's events: deltas, tool activity, emits, and the completion, failure or cancellation that ends it.

  Part of `Aqua.ConversationRunner`: every function here takes the
  runner's state and answers the state, and is called from the runner's
  callbacks alone — the public face stays `Aqua.ConversationRunner`.
  """

  require Logger
  alias Arca.ConversationStorage, as: Conversations
  alias Aqua.Turn, as: AquaTurn

  # The two reserved authors, as the schema spells them: the assistant's
  # own speech, and the runner's voice.
  @agent_author Arca.Schemas.Message.agent_author()
  @system_author Arca.Schemas.Message.system_author()
  # Cap streamed text and tool output before broadcasting to viewers.
  @max_streaming_text_bytes 512 * 1024
  @max_tool_activity 200

  @doc false
  def ref_note(ref) when is_binary(ref) and ref != "", do: " (#{ref})"
  def ref_note(_), do: ""

  # One gate for every execution event, live or replayed: a finished turn
  # takes no more events, and an event delivered twice (buffered AND live)
  # must apply once — the producer's sequence is the dedup key.
  @doc false
  def apply_sequenced_event(%{running: false} = state, _event), do: state

  def apply_sequenced_event(state, %{sequence: seq} = event) when is_integer(seq) do
    if seq <= state.last_event_seq do
      state
    else
      apply_execution_event(%{state | last_event_seq: seq}, event)
    end
  end

  def apply_sequenced_event(state, event), do: apply_execution_event(state, event)

  @doc false
  def apply_execution_event(state, %{type: "emit", data: data}) do
    handle_emit(state, data["kind"] || data[:kind], data)
  end

  def apply_execution_event(state, %{type: "complete"}), do: complete_turn(state)

  def apply_execution_event(state, %{type: "error", data: data}) do
    # Producers spell the reason under `:error` (every
    # `ExecutionEventBuffer.push_terminal/5` caller); an unrecognized shape
    # is logged, never inspected into a row every member reads.
    case data[:error] || data["error"] do
      msg when is_binary(msg) ->
        fail_turn(state, msg)

      _ ->
        Logger.warning(
          "[Aqua.ConversationRunner] error event with unrecognized data keys: " <>
            inspect(if is_map(data), do: Map.keys(data), else: data)
        )

        fail_turn(state, "The turn failed.")
    end
  end

  def apply_execution_event(state, _other), do: state

  # A supervisor stop (a shutdown, a rolling deploy) mid-turn: write the
  # interruption while the Repo is still up, drop the queue, and let the
  # engine know — inline, since a task started here would die with us. A
  # crash writes nothing and keeps the row's `execution_id`, so the
  # transient restart re-follows a still-live execution.

  @doc false
  def shutdown(state, why \\ "the server stopped") do
    exec_id = state.execution_id
    ctx = state.turn_ctx || state.system_ctx

    state =
      state
      |> Aqua.Runner.Addressing.clear_queue()
      |> Aqua.Runner.Recovery.interrupted(exec_id, why, "cancelled")

    if exec_id do
      state.turn.unsubscribe(exec_id, ctx)
      state.turn.cancel(ctx, exec_id)
    end

    state
  rescue
    e ->
      # Shutdown must not crash, but a failed cancel leaves the execution
      # running server-side while this runner reports itself stopped —
      # that orphan must be visible.
      Logger.warning(
        "[Aqua.ConversationRunner] shutdown cancel failed for #{inspect(state.execution_id)}: " <>
          Exception.message(e)
      )

      %{state | running: false, execution_id: nil}
  catch
    :exit, reason ->
      Logger.warning(
        "[Aqua.ConversationRunner] shutdown cancel exited for #{inspect(state.execution_id)}: " <>
          inspect(reason)
      )

      %{state | running: false, execution_id: nil}
  end

  # Close the turn row using the execution id captured before
  # `finish_turn/1` clears it. Log storage failures without failing the turn.
  @doc false
  def close_turn_row(state, execution_id, status, error) when is_binary(execution_id) do
    case Arca.TurnStorage.close(state.system_ctx, execution_id, status, error) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Aqua.ConversationRunner] turn not closed: #{inspect(reason)}")
    end
  end

  def close_turn_row(_state, _execution_id, _status, _error), do: :ok

  # ---------------------------------------------------------------------------
  # Emits
  # ---------------------------------------------------------------------------

  @doc false
  def handle_emit(state, "text_delta", data) do
    chunk = data["content"] || data[:content] || ""
    streamed = byte_size(state.streaming_text)

    cond do
      streamed >= @max_streaming_text_bytes ->
        state

      streamed + byte_size(chunk) > @max_streaming_text_bytes ->
        marker = "\n\n_(output truncated)_"

        %{state | streaming_text: state.streaming_text <> marker}
        |> Aqua.Runner.Shared.broadcast({:delta, marker})

      true ->
        %{state | streaming_text: state.streaming_text <> chunk}
        |> Aqua.Runner.Shared.broadcast({:delta, chunk})
    end
  end

  def handle_emit(state, "tool_use", data) do
    if length(state.tool_activity) >= @max_tool_activity do
      state
    else
      tool = data["tool"] || data[:tool] || "tool"
      activity = state.tool_activity ++ [%{tool: tool, status: :running, preview: nil}]

      %{state | tool_activity: activity}
      |> Aqua.Runner.Shared.broadcast({:tool_activity, activity})
    end
  end

  def handle_emit(state, "tool_result", data) do
    tool = data["tool"] || data[:tool] || "tool"
    preview = data["preview"] || data[:preview]
    activity = AquaTurn.mark_tool_done(state.tool_activity, tool, preview)
    %{state | tool_activity: activity} |> Aqua.Runner.Shared.broadcast({:tool_activity, activity})
  end

  # Whatever the component still needs, the consent walk is the one place
  # it gets granted — the sender is shown the sheet for the asking ref.
  def handle_emit(state, kind, data) when kind in ["setup_required", "request_setup"] do
    case data["component_ref"] || data[:component_ref] || "" do
      "" ->
        state

      ref ->
        Aqua.Runner.Shared.broadcast(
          state,
          {:consent_required, ref, Aqua.Runner.Shared.turn_user(state)}
        )
    end
  end

  def handle_emit(state, "usage", data) do
    input = data["input_tokens"] || data[:input_tokens] || 0
    output = data["output_tokens"] || data[:output_tokens] || 0
    usage = %{input: state.usage.input + input, output: state.usage.output + output}
    %{state | usage: usage} |> Aqua.Runner.Shared.broadcast({:usage, usage})
  end

  # The formula's full history (provider-canonical shape); kept for the
  # next turn so the agent has multi-turn memory. Notes appended while the
  # turn ran (an approval outcome) ride along, not under it.
  def handle_emit(state, "conversation_complete", data) do
    history = (data["messages"] || data[:messages] || []) ++ state.notes_in_flight

    # `last_task` goes with the notes. This list is the model's own, and it
    # already contains this turn's user message — so the fold that
    # `fail_turn`/`cancel_turn` apply for turns that ended BEFORE the model
    # spoke would add it a second time, and every later turn would read it
    # twice. Cleared here because those two fold before `finish_turn/1`
    # ever runs.
    %{state | history: history, notes_in_flight: [], last_task: nil}
  end

  def handle_emit(state, _kind, _data), do: state

  # ---------------------------------------------------------------------------
  # Turn end
  # ---------------------------------------------------------------------------

  @doc false
  def complete_turn(state) do
    ctx = state.turn_ctx || state.system_ctx
    if state.execution_id, do: state.turn.unsubscribe(state.execution_id, ctx)
    close_turn_row(state, state.execution_id, "completed", nil)

    %{text: text, approvals: approvals, intents: intents, tripwires: tripwires} =
      AquaTurn.parse_completion(state.streaming_text, state.tool_policy)

    # No bang-matches on the appends: a store hiccup here must degrade to
    # a broadcast error, never crash the runner mid-completion and drop
    # the whole turn's bookkeeping.
    state =
      if text != "" do
        case Conversations.append(ctx, state.id, %{
               author: @agent_author,
               kind: "text",
               content: text,
               execution_id: state.execution_id
             }) do
          {:ok, row} ->
            Aqua.Runner.Shared.broadcast(state, {:message, row})

          {:error, reason} ->
            Logger.error("[Aqua.ConversationRunner] reply append failed: #{inspect(reason)}")
            Aqua.Runner.Shared.broadcast(state, {:error, "The reply could not be saved"})
        end
      else
        state
      end

    orchestrator_name = state.orchestrator && state.orchestrator.name

    approval_rows =
      Enum.flat_map(approvals, fn intent ->
        case Conversations.append(ctx, state.id, %{
               id: intent.id,
               author: @agent_author,
               kind: "approval",
               content: intent.title,
               status: "pending",
               # The card names its agent: a card can be decided after the
               # next turn started, when the runner's own pick is the next
               # turn's — the standing grant files under the card's agent,
               # never the runner's.
               payload: %{"intent" => intent, "orchestrator" => orchestrator_name},
               execution_id: state.execution_id
             }) do
          {:ok, row} ->
            [row]

          {:error, reason} ->
            Logger.error("[Aqua.ConversationRunner] approval append failed: #{inspect(reason)}")

            []
        end
      end)

    state = Enum.reduce(approval_rows, state, &Aqua.Runner.Shared.broadcast(&2, {:message, &1}))

    state =
      Enum.reduce(tripwires, state, fn text, acc ->
        case Conversations.append(ctx, acc.id, %{
               author: @system_author,
               kind: "error",
               content: text
             }) do
          {:ok, row} -> Aqua.Runner.Shared.broadcast(acc, {:message, row})
          {:error, _} -> Aqua.Runner.Shared.broadcast(acc, {:error, text})
        end
      end)

    if approval_rows != [] do
      Sanctum.Notify.broadcast(state.athanor_id, :approval_pending, %{
        conversation_id: state.id,
        count: length(approval_rows)
      })
    end

    # What this turn was, taken BEFORE `finish_turn/1` clears the turn:
    # the completion's effects — the intents' recipient, the cards' fast
    # path — are addressed from this envelope, never from state that a
    # later step has already reset.
    result = %{
      user_id: Aqua.Runner.Shared.turn_user(state),
      execution_id: state.execution_id,
      profile_id: state.profile_id,
      agent: orchestrator_name
    }

    state =
      state
      |> finish_turn()
      |> broadcast_intents(intents, result.user_id)

    # Conversation-grant fast path: a proposal the members already chose to
    # auto-approve "for this chat" runs at once — for the agent the CARD
    # names, and as `:once`: the grant is what admitted the call, and the
    # call does not record it again.
    state =
      Enum.reduce(approval_rows, state, fn row, acc ->
        intent = Aqua.Runner.Approvals.approval_intent(row)

        if AquaTurn.granted?(
             Aqua.Runner.Approvals.approval_orchestrator(row),
             Aqua.Runner.Approvals.atomize_intent(intent),
             acc.grants
           ) do
          case Conversations.resolve_approval(ctx, row.id, "pending", "running", %{
                 resolution: %{"scope" => :conversation}
               }) do
            {:ok, msg} -> Aqua.Runner.Approvals.run_approval(acc, ctx, msg, :once)
            _ -> acc
          end
        else
          acc
        end
      end)

    Aqua.Runner.Addressing.start_next(state)
  end

  @doc false
  def broadcast_intents(state, [], _user_id), do: state

  def broadcast_intents(state, intents, user_id),
    do: Aqua.Runner.Shared.broadcast(state, {:intents, intents, user_id})

  @doc false
  def fail_turn(state, text) do
    ctx = state.turn_ctx || state.system_ctx
    if state.execution_id, do: state.turn.unsubscribe(state.execution_id, ctx)
    close_turn_row(state, state.execution_id, "failed", text)

    state =
      case Conversations.append(ctx, state.id, %{
             author: @system_author,
             kind: "error",
             content: text
           }) do
        {:ok, row} -> Aqua.Runner.Shared.broadcast(state, {:message, row})
        _ -> Aqua.Runner.Shared.broadcast(state, {:error, text})
      end

    # Preserve the consumed task in history when a turn fails.
    user_turn =
      if state.last_task,
        do: [%{"role" => "user", "content" => state.last_task}],
        else: []

    partial = state.streaming_text

    assistant_turn =
      if partial != "",
        do: [%{"role" => "assistant", "content" => partial <> "\n\n(failed)"}],
        else: []

    state = %{
      state
      | history: state.history ++ user_turn ++ assistant_turn ++ state.notes_in_flight,
        notes_in_flight: []
    }

    # On failure, drop queued entries with a note instead of launching them.
    state =
      if state.queue != [] do
        state
        |> Aqua.Runner.Recovery.append_and_broadcast(%{
          author: @system_author,
          kind: "system",
          content:
            "The waiting turn was dropped because this one failed — the messages stay " <>
              "in the thread; send again to continue."
        })
        |> Aqua.Runner.Addressing.clear_queue()
      else
        state
      end

    finish_turn(state)
  end

  # Cancel an in-flight turn: unsubscribe, ask the engine to stop, keep the
  # partial reply as a message, and synthesise the user + truncated
  # assistant turns into the history so the next message keeps context.
  @doc false
  def cancel_turn(state, ctx) do
    exec_id = state.execution_id
    turn_ctx = state.turn_ctx || ctx
    turn = state.turn
    close_turn_row(state, state.execution_id, "cancelled", nil)

    if exec_id do
      turn.unsubscribe(exec_id, turn_ctx)

      # A refused spawn is logged by start_task; the sweeper reaps the
      # execution the cancel would have stopped.
      _ = Aqua.Runner.Addressing.start_task(fn -> turn.cancel(ctx, exec_id) end)
    end

    partial = state.streaming_text

    state =
      if partial != "" do
        # No bang-match — the same rule complete_turn states: a store
        # hiccup must degrade to a broadcast, never crash the runner
        # mid-cancel. A crash here is worse than mid-completion: it skips
        # terminate/2 (which fires only on normal/shutdown), so the engine
        # is never told to cancel and the execution orphans.
        case Conversations.append(turn_ctx, state.id, %{
               author: @agent_author,
               kind: "text",
               content: partial <> "\n\n_(cancelled)_",
               execution_id: exec_id
             }) do
          {:ok, row} ->
            Aqua.Runner.Shared.broadcast(state, {:message, row})

          {:error, _} ->
            Aqua.Runner.Shared.broadcast(
              state,
              {:error, "the cancelled reply could not be saved"}
            )
        end
      else
        state
      end

    user_turn =
      if state.last_task,
        do: [%{"role" => "user", "content" => state.last_task}],
        else: []

    assistant_turn =
      if partial != "",
        do: [%{"role" => "assistant", "content" => partial <> "\n\n(cancelled)"}],
        else: []

    %{
      state
      | history: state.history ++ user_turn ++ assistant_turn ++ state.notes_in_flight,
        notes_in_flight: []
    }
    |> finish_turn()
  end

  # Persist the history and clear the running execution; broadcast the end.
  @doc false
  def finish_turn(state) do
    # Bound history before persisting it and retaining it in the runner.
    history = Aqua.ConversationCompactor.compact(state.history)

    Conversations.update(state.system_ctx, state.id, %{
      history: history,
      execution_id: nil
    })

    %{
      state
      | history: history,
        running: false,
        execution_id: nil,
        starting: nil,
        cancel_requested: false,
        streaming_text: "",
        tool_activity: [],
        turn_ctx: nil,
        # Clear merged notes so subsequent turns do not append them again.
        notes_in_flight: [],
        # Clear the consumed task after completion. The returned history already
        # contains it; failure and cancellation recovery must not append it again.
        last_task: nil
    }
    |> Aqua.Runner.Shared.broadcast({:turn_finished})
    |> Aqua.Runner.Shared.touch()
  end
end
