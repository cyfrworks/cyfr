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

  @doc "Follow a thread. Idempotent — following twice is following."
  @spec follow(Cyfr.Actor.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def follow(%Cyfr.Actor{athanor_id: athanor_id}, thread_id, user_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(thread_id) and
             is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.ThreadSubscriptionStorage.follow", fn ->
      row = %{
        id: Cyfr.UUID7.generate_id("sub"),
        athanor_id: athanor_id,
        thread_id: thread_id,
        user_id: user_id,
        joined_at: DateTime.utc_now()
      }

      %ThreadSubscription{}
      |> Ecto.Changeset.change(row)
      |> Arca.Repo.insert(on_conflict: :nothing, conflict_target: [:thread_id, :user_id])

      :ok
    end)
    |> Arca.Data.project()
  end

  def follow(%Cyfr.Actor{}, _thread_id, _user_id), do: {:error, :no_athanor}

  @doc "Stop following. Idempotent."
  @spec unfollow(Cyfr.Actor.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def unfollow(%Cyfr.Actor{athanor_id: athanor_id}, thread_id, user_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(thread_id) and
             is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.ThreadSubscriptionStorage.unfollow", fn ->
      from(s in ThreadSubscription,
        where:
          s.athanor_id == ^athanor_id and
            s.thread_id == ^thread_id and s.user_id == ^user_id
      )
      |> Arca.Repo.delete_all()

      :ok
    end)
    |> Arca.Data.project()
  end

  def unfollow(%Cyfr.Actor{}, _thread_id, _user_id), do: {:error, :no_athanor}

  @doc "The thread ids this person follows in the context's athanor."
  @spec followed(Cyfr.Actor.t(), String.t()) :: MapSet.t(String.t())
  def followed(%Cyfr.Actor{athanor_id: athanor_id}, user_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(user_id) do
    # Deliberate default: an unanswerable read means "following nothing",
    # so the sidebar renders every thread collapsed. Every one is still
    # reachable — access was never this table's to decide — so the failure
    # costs an expanded list, not a thread.
    Arca.Repo.Errors.with_db_rescue("Arca.ThreadSubscriptionStorage.followed", MapSet.new(), fn ->
      from(s in ThreadSubscription,
        where: s.athanor_id == ^athanor_id and s.user_id == ^user_id,
        select: s.thread_id
      )
      |> Arca.Repo.all()
      |> MapSet.new()
    end)
  end

  def followed(%Cyfr.Actor{}, _user_id), do: {:error, :no_athanor}

  @doc """
  Whether one person follows one thread — the notify filter's read.

  The tray reads it for athanors the person is NOT focused on, so the
  caller names each one with an actor of its own
  (`Cyfr.Actor.in_athanor/1`) rather than the focused context. Fails
  toward "no", so an unanswerable read costs a badge, never a wrong one.
  """
  @spec follows?(Cyfr.Actor.t(), String.t(), String.t()) :: boolean()
  def follows?(%Cyfr.Actor{athanor_id: athanor_id}, thread_id, user_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(thread_id) and
             is_binary(user_id) do
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
    |> Arca.Data.project()
  end

  # Fails toward "no" for an actor with no athanor and for an absent
  # thread or person; anything that is not an actor at all matches no head
  # and raises, so a context cannot be read as "does not follow".
  def follows?(%Cyfr.Actor{}, _thread_id, _user_id), do: false

  @doc """
  Drop every follow this person holds in the athanor — what leaving it
  owes this table. A follow names nothing that outlives the seat; left
  standing, it would resume the moment the person is re-added.

  Takes the athanor id directly (tenant first), like `follows?/3`: the
  caller is the membership removal, which holds no context focused on the
  athanor being left. Strict — the leave reports a sweep the store could
  not do rather than answering "done" over surviving rows.
  """
  @spec unfollow_all(Cyfr.Actor.t(), String.t()) :: :ok | {:error, term()}
  def unfollow_all(%Cyfr.Actor{athanor_id: athanor_id}, user_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.ThreadSubscriptionStorage.unfollow_all", fn ->
      from(s in ThreadSubscription, where: s.athanor_id == ^athanor_id and s.user_id == ^user_id)
      |> Arca.Repo.delete_all()

      :ok
    end)
    |> Arca.Data.project()
  end

  def unfollow_all(%Cyfr.Actor{}, _user_id), do: {:error, :no_athanor}
end
