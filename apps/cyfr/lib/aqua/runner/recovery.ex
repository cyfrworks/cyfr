# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Runner.Recovery do
  @moduledoc """
  A runner that comes back to a turn that was running when it went away.

  Part of `Aqua.ConversationRunner`: every function here takes the
  runner's state and answers the state, and is called from the runner's
  callbacks alone — the public face stays `Aqua.ConversationRunner`.
  """

  require Logger
  alias Arca.ConversationStorage, as: Conversations
  alias Aqua.Orchestrator
  alias Sanctum.Context

  # The two reserved authors, as the schema spells them: the assistant's
  # own speech, and the runner's voice.
  @agent_author Arca.Schemas.Message.agent_author()
  @system_author Arca.Schemas.Message.system_author()
  @recover_retry_ms 2_000

  # ---------------------------------------------------------------------------
  # Recovery
  # ---------------------------------------------------------------------------

  # A turn that was running when the server stopped. If the engine is not
  # up yet, wait for it; if the execution is still running, follow it again
  # (its buffered events replay through the same handlers); if it finished
  # meanwhile, close the turn off with what the buffer still holds.
  # `stored` is the pick off the conversation row — its name — or nil for
  # a row that recorded none.
  @spec recover(map(), String.t(), Orchestrator.t() | nil, non_neg_integer()) :: map()
  def recover(state, execution_id, stored, attempts) do
    ctx = state.system_ctx
    turn = state.turn

    cond do
      state.running ->
        state

      not turn.engine_available?() and attempts > 0 ->
        Process.send_after(
          self(),
          {:recover, execution_id, stored, attempts - 1},
          @recover_retry_ms
        )

        state

      not turn.engine_available?() ->
        interrupted(state, execution_id, "no execution engine")

      true ->
        # The standing answers are read before the turn is followed again,
        # composed into the policy exactly as `Aqua.Turn.begin/5` composes
        # them: a recovered completion must not treat a denied pair as
        # callable just because the runner restarted. A store that cannot
        # answer is retried like an engine that is not up yet, then the
        # turn is interrupted — recovering on the authored policy alone
        # would make a standing "never" on an authored `auto` pair callable
        # again until the store returned, the wider reading `begin/5`
        # refuses too.
        case standing(ctx, state, stored) do
          :unavailable when attempts > 0 ->
            Process.send_after(
              self(),
              {:recover, execution_id, stored, attempts - 1},
              @recover_retry_ms
            )

            state

          :unavailable ->
            interrupted(state, execution_id, "the standing answers could not be read")

          {:ok, orchestrator, grants} ->
            follow(state, execution_id, orchestrator, grants)
        end
    end
  end

  # The recorded pick resolved against the tree as it is now, with its
  # standing rows composed in and the fast-path set beside it; `nil` for a
  # row that recorded no pick or a tree that no longer holds it.
  defp standing(ctx, state, stored) do
    case resolve_stored(ctx, stored || state.orchestrator) do
      %Orchestrator{} = resolved ->
        with {:ok, rows} <- Aqua.ToolGrants.for_conversation(ctx, state.id, resolved.name),
             {:ok, allowed} <- Aqua.ToolGrants.allowed_by_agent(ctx, state.id) do
          {:ok, Orchestrator.with_grants(resolved, rows), allowed}
        else
          {:error, _} -> :unavailable
        end

      nil ->
        {:ok, nil, state.grants}
    end
  end

  # Follow the execution again. Subscribe before reading the buffer: an
  # event landing between the two reads would otherwise be lost, and the
  # sequence gate drops any the buffer and the live feed both deliver.
  defp follow(state, execution_id, orchestrator, grants) do
    ctx = state.system_ctx
    turn = state.turn

    turn.subscribe(execution_id, ctx)
    events = turn.events_since(execution_id, state.athanor_id)
    finished? = Enum.any?(events, &(&1.type in ["complete", "error"]))

    state = %{
      state
      | running: true,
        execution_id: execution_id,
        last_event_seq: -1,
        turn_ctx: ctx,
        orchestrator: orchestrator,
        grants: grants,
        tool_policy: Orchestrator.tool_policy(orchestrator),
        # The pin is on the execution row precisely so a turn that
        # outlived its runner can still answer "under which consent?".
        # An approval decided after a restart roots the same profile
        # the turn did, not whatever a fresh selection would pick.
        profile_id: state.profile_id || pinned_profile(ctx, execution_id)
    }

    state = replay(state, events)

    cond do
      finished? ->
        # The replayed complete/error already unsubscribed.
        state

      turn.running?(ctx, execution_id) ->
        Aqua.Runner.Shared.broadcast(state, {:turn_started, execution_id})

      true ->
        turn.unsubscribe(execution_id, ctx)
        interrupted(state, execution_id, "the server restarted")
    end
  end

  # The recorded pick — its identity — read back from the estate's tree as
  # the tree holds it NOW. A tree that no longer holds the agent recovers
  # with no orchestrator — the same deliberate fail-open
  # `Aqua.Turn.orchestrator/3` states.
  @spec resolve_stored(Context.t(), Orchestrator.t() | nil) :: Orchestrator.t() | nil
  def resolve_stored(_ctx, nil), do: nil

  @doc false
  def resolve_stored(ctx, %Orchestrator{} = stored) do
    case Orchestrator.resolve(ctx, Orchestrator.identity(stored)) do
      {:ok, resolved} -> resolved
      {:error, :no_orchestrator} -> nil
    end
  end

  # The profile a running execution rooted under, off its own row. Nil when
  # the read fails or the row predates the column: `run_approval/4` then
  # refuses the approval rather than rooting a re-selected authority, which
  # is the whole point of pinning.
  @doc false
  def pinned_profile(ctx, execution_id) do
    case Cyfr.Execution.get(ctx, execution_id) do
      {:ok, %{profile_id: id}} when is_binary(id) ->
        id

      {:ok, _unpinned} ->
        nil

      {:error, reason} ->
        # A read that failed is not a row that never pinned: say which, so
        # a refused approval can be traced to the store and not the column.
        Logger.warning(
          "[Aqua.ConversationRunner] execution #{execution_id} could not be read for its " <>
            "profile: #{inspect(reason)}"
        )

        nil
    end
  end

  @doc false
  def replay(state, events),
    do: Enum.reduce(events, state, &Aqua.Runner.Stream.apply_sequenced_event(&2, &1))

  @doc false
  def interrupted(state, execution_id, why) do
    state =
      if state.streaming_text != "" do
        append_and_broadcast(state, %{
          author: @agent_author,
          kind: "text",
          content: state.streaming_text <> "\n\n_(interrupted)_",
          execution_id: execution_id
        })
      else
        state
      end

    state
    |> append_and_broadcast(%{
      author: @system_author,
      kind: "system",
      content: "This turn was interrupted — #{why}. Send the message again to continue."
    })
    |> Map.put(:running, true)
    |> Aqua.Runner.Stream.finish_turn()
  end

  @doc false
  def append_and_broadcast(state, attrs) do
    case Conversations.append(state.system_ctx, state.id, attrs) do
      {:ok, row} -> Aqua.Runner.Shared.broadcast(state, {:message, row})
      {:error, _} -> state
    end
  end
end
