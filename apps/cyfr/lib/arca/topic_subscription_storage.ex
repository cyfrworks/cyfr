# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.TopicSubscriptionStorage do
  @moduledoc """
  Persistence for topic follows. Presence-only: the row is the fact, so
  there is nothing to update — `follow/3` is idempotent and `unfollow/3`
  deletes.

  Access is not decided here or anywhere near here; see
  `Arca.Schemas.TopicSubscription`.
  """

  import Ecto.Query

  alias Arca.Schemas.TopicSubscription
  alias Sanctum.Context

  @doc "Follow a topic. Idempotent — following twice is following."
  @spec follow(Context.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def follow(%Context{} = ctx, conversation_id, user_id)
      when is_binary(conversation_id) and is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TopicSubscriptionStorage.follow", fn ->
      row = %{
        id: Cyfr.UUID7.generate_id("sub"),
        athanor_id: Context.athanor!(ctx),
        conversation_id: conversation_id,
        user_id: user_id,
        joined_at: DateTime.utc_now()
      }

      %TopicSubscription{}
      |> Ecto.Changeset.change(row)
      |> Arca.Repo.insert(on_conflict: :nothing, conflict_target: [:conversation_id, :user_id])

      :ok
    end)
  end

  @doc "Stop following. Idempotent."
  @spec unfollow(Context.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def unfollow(%Context{} = ctx, conversation_id, user_id)
      when is_binary(conversation_id) and is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TopicSubscriptionStorage.unfollow", fn ->
      from(s in TopicSubscription,
        where:
          s.athanor_id == ^Context.athanor!(ctx) and
            s.conversation_id == ^conversation_id and s.user_id == ^user_id
      )
      |> Arca.Repo.delete_all()

      :ok
    end)
  end

  @doc "The conversation ids this person follows in the context's athanor."
  @spec followed(Context.t(), String.t()) :: MapSet.t(String.t())
  def followed(%Context{} = ctx, user_id) when is_binary(user_id) do
    # Deliberate default: an unanswerable read means "following nothing",
    # so the sidebar renders every topic collapsed. Every one is still
    # reachable — access was never this table's to decide — so the failure
    # costs an expanded list, not a conversation.
    Arca.Repo.Errors.with_db_rescue("Arca.TopicSubscriptionStorage.followed", MapSet.new(), fn ->
      from(s in TopicSubscription,
        where: s.athanor_id == ^Context.athanor!(ctx) and s.user_id == ^user_id,
        select: s.conversation_id
      )
      |> Arca.Repo.all()
      |> MapSet.new()
    end)
  end

  @doc """
  Whether one person follows one topic — the notify filter's read.

  Takes the athanor id directly (tenant first) rather than a context: the
  tray reads it for athanors the person is NOT focused on. Fails toward
  "no", so an unanswerable read costs a badge, never a wrong one.
  """
  @spec follows?(String.t(), String.t(), String.t()) :: boolean()
  def follows?(athanor_id, conversation_id, user_id)
      when is_binary(athanor_id) and is_binary(conversation_id) and is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TopicSubscriptionStorage.follows?", false, fn ->
      from(s in TopicSubscription,
        where:
          s.athanor_id == ^athanor_id and s.conversation_id == ^conversation_id and
            s.user_id == ^user_id,
        select: count(s.id)
      )
      |> Arca.Repo.one()
      |> Kernel.>(0)
    end)
  end

  def follows?(_, _, _), do: false

  @doc "Who follows this topic — the notify roster."
  @spec followers(Context.t(), String.t()) :: [String.t()]
  def followers(%Context{} = ctx, conversation_id) when is_binary(conversation_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TopicSubscriptionStorage.followers", [], fn ->
      from(s in TopicSubscription,
        where: s.athanor_id == ^Context.athanor!(ctx) and s.conversation_id == ^conversation_id,
        select: s.user_id,
        order_by: [asc: s.joined_at]
      )
      |> Arca.Repo.all()
    end)
  end
end
