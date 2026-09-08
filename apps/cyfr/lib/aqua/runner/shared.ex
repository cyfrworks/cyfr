# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Runner.Shared do
  @moduledoc """
  What every part of the runner reads and says: the state's public projection, who is acting, and the one broadcast.

  Part of `Aqua.ConversationRunner`: every function here takes the
  runner's state and answers the state, and is called from the runner's
  callbacks alone — the public face stays `Aqua.ConversationRunner`.
  """

  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Members}

  # A runner with nothing to do for this long stops; the next send starts it again.
  @idle_ms :timer.minutes(15)

  @doc false
  def same_conversation(%{conversation_id: id}, id), do: :ok
  def same_conversation(_msg, _id), do: {:error, :not_found}

  # What every act in a live conversation is held to: the furnace is open and
  # the caller still belongs to it.
  @doc false
  def standing(%Context{} = ctx, state) do
    cond do
      not Athanors.active?(state.athanor_id) -> {:error, :archived}
      not may_act?(ctx, state) -> {:error, :not_member}
      true -> :ok
    end
  end

  # A member of the athanor may act — and only a member. An operator who
  # opened an estate they are not seated in (`Context.focus/2` audited
  # that) reads it; sending, deciding a card or revoking a grant there
  # would put their words and answers on a tape they do not belong to,
  # the same doctrine `Aqua.Aloud` holds. A context minted at mount is
  # not trusted forever: this is re-asked on every send and at every
  # dequeue.
  @doc false
  def may_act?(%Context{user_id: user_id}, state), do: Members.member?(user_id, state.athanor_id)

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc false
  def public_state(state) do
    %{
      running: state.running,
      athanor_id: state.athanor_id,
      execution_id: state.execution_id,
      streaming_text: state.streaming_text,
      tool_activity: state.tool_activity,
      usage: state.usage,
      # `{agent_name, tool, action}`: what runs with no card, and for whom.
      grants: state.grants,
      # The resolved detail, string-keyed: the console reads its title and
      # model and hands the same map back as the next send's pick.
      orchestrator: state.orchestrator && state.orchestrator.agent,
      turn_user: turn_user(state),
      queued: length(state.queue),
      # Derived, not stored: whether this estate needs a mention.
      solo_human: Aqua.Runner.Addressing.solo_human?(state)
    }
  end

  @doc false
  def turn_user(%{turn_ctx: %Context{user_id: user_id}}), do: user_id
  def turn_user(_), do: nil

  @doc false
  def broadcast(state, event) do
    Phoenix.PubSub.broadcast(
      Emissary.PubSub,
      Aqua.ConversationRunner.topic(state.id, state.athanor_id),
      {:conversation, state.id, event}
    )

    state
  end

  @doc false
  def touch(state) do
    if state.idle_ref, do: Process.cancel_timer(state.idle_ref)
    %{state | idle_ref: Process.send_after(self(), :idle, @idle_ms)}
  end

  # The runner's own hands inside the athanor: reads and the rows the agent
  # writes (the agent's author, or the system's) when no member's context
  # applies.
  @doc false
  def system_ctx(athanor_id) do
    Sanctum.internal_context(user_id: "_conversations", athanor_id: athanor_id, scope: :athanor)
  end
end
