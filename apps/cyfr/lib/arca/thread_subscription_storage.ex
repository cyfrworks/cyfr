# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ThreadSubscriptionStorage do
  @moduledoc """
  Persistence for thread follows. Presence-only: the row is the fact, so
  there is nothing to update — `follow/3` is idempotent and `unfollow/3`
  deletes.

  Access is not decided here or anywhere near here; see
  `Arca.Schemas.ThreadSubscription`.
  """

  import Ecto.Query

  alias Arca.Schemas.ThreadSubscription
  alias Sanctum.Context

  @doc "Follow a thread. Idempotent — following twice is following."
  @spec follow(Context.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def follow(%Context{} = ctx, thread_id, user_id)
      when is_binary(thread_id) and is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.ThreadSubscriptionStorage.follow", fn ->
      row = %{
        id: Cyfr.UUID7.generate_id("sub"),
        athanor_id: Context.athanor!(ctx),
        thread_id: thread_id,
        user_id: user_id,
        joined_at: DateTime.utc_now()
      }

      %ThreadSubscription{}
      |> Ecto.Changeset.change(row)
      |> Arca.Repo.insert(on_conflict: :nothing, conflict_target: [:thread_id, :user_id])

      :ok
    end)
  end

  @doc "Stop following. Idempotent."
  @spec unfollow(Context.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def unfollow(%Context{} = ctx, thread_id, user_id)
      when is_binary(thread_id) and is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.ThreadSubscriptionStorage.unfollow", fn ->
      from(s in ThreadSubscription,
        where:
          s.athanor_id == ^Context.athanor!(ctx) and
            s.thread_id == ^thread_id and s.user_id == ^user_id
      )
      |> Arca.Repo.delete_all()

      :ok
    end)
  end

  @doc "The thread ids this person follows in the context's athanor."
  @spec followed(Context.t(), String.t()) :: MapSet.t(String.t())
  def followed(%Context{} = ctx, user_id) when is_binary(user_id) do
    # Deliberate default: an unanswerable read means "following nothing",
    # so the sidebar renders every thread collapsed. Every one is still
    # reachable — access was never this table's to decide — so the failure
    # costs an expanded list, not a thread.
    Arca.Repo.Errors.with_db_rescue("Arca.ThreadSubscriptionStorage.followed", MapSet.new(), fn ->
      from(s in ThreadSubscription,
        where: s.athanor_id == ^Context.athanor!(ctx) and s.user_id == ^user_id,
        select: s.thread_id
      )
      |> Arca.Repo.all()
      |> MapSet.new()
    end)
  end

  @doc """
  Whether one person follows one thread — the notify filter's read.

  Takes the athanor id directly (tenant first) rather than a context: the
  tray reads it for athanors the person is NOT focused on. Fails toward
  "no", so an unanswerable read costs a badge, never a wrong one.
  """
  @spec follows?(String.t(), String.t(), String.t()) :: boolean()
  def follows?(athanor_id, thread_id, user_id)
      when is_binary(athanor_id) and is_binary(thread_id) and is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.ThreadSubscriptionStorage.follows?", false, fn ->
      from(s in ThreadSubscription,
        where:
          s.athanor_id == ^athanor_id and s.thread_id == ^thread_id and
            s.user_id == ^user_id,
        select: count(s.id)
      )
      |> Arca.Repo.one()
      |> Kernel.>(0)
    end)
  end

  def follows?(_, _, _), do: false

  @doc """
  Drop every follow this person holds in the athanor — what leaving it
  owes this table. A follow names nothing that outlives the seat; left
  standing, it would resume the moment the person is re-added.

  Takes the athanor id directly (tenant first), like `follows?/3`: the
  caller is the membership removal, which holds no context focused on the
  athanor being left. Strict — the leave reports a sweep the store could
  not do rather than answering "done" over surviving rows.
  """
  @spec unfollow_all(String.t(), String.t()) :: :ok | {:error, term()}
  def unfollow_all(athanor_id, user_id) when is_binary(athanor_id) and is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.ThreadSubscriptionStorage.unfollow_all", fn ->
      from(s in ThreadSubscription, where: s.athanor_id == ^athanor_id and s.user_id == ^user_id)
      |> Arca.Repo.delete_all()

      :ok
    end)
  end
end
