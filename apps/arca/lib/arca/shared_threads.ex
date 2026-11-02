# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SharedThreads do
  @moduledoc """
  Shared threads (`Arca.Schemas.SharedThread`): places people talk in,
  which no athanor holds. A `shared` thread has a title and the people
  seated in it (`Arca.SharedThreadMembers`); a `pair` is two people, made
  once for them and named by `pair_of`, the two user ids sorted and joined
  with `:`, which no other active pair holds. Who may make, rename, archive
  or reopen one is `Sanctum.SharedThreads`'.

  ## The first argument

  Every function matches `scope: :platform` and refuses any other actor
  with `{:error, :cross_tenant}`: a shared thread is no athanor's, so no
  athanor-scoped actor can name one, and its people are read across every
  athanor they hold.

  ## Writes

  A thread and its seats widen who reads what is said in it, so every
  write runs under this member's slot (`Arca.Repo.owned/2`; `:not_owner`
  once another member holds it). The people a write seats are locked first
  and the thread after them, the order a person's standing transitions
  take (`Arca.SecurityTransitions`). Archiving or reopening a thread
  raises its `security_generation` by one in the same statement.

  A row crosses as a plain map (`Arca.Data`). A refusal is `:not_found`,
  `:pair` (a pair has no title and stays ended once archived),
  `{:invalid, %{field => [message]}}`, `:cross_tenant`, `:not_owner` or
  `:database_error`.
  """

  import Ecto.Query

  alias Arca.QueryHelpers
  alias Arca.Schemas.{SharedThread, SharedThreadMember}
  alias Arca.SharedThreadMembers

  @typedoc "A shared thread row, as a plain map."
  @type row :: map()

  @type refusal :: {:error, :cross_tenant | :not_owner | :database_error}

  @doc """
  Make a thread of people: `attrs` names its `:title` and the person it is
  `:created_by`, who is seated in it in the same transaction.
  """
  @spec create(Prima.Actor.t(), map()) :: {:ok, row()} | {:error, {:invalid, map()}} | refusal()
  # arca:unscoped-ok a shared thread is no athanor's; it is written with its first seat.
  def create(%Prima.Actor{scope: :platform}, attrs) when is_map(attrs) do
    title = attrs[:title]
    by = attrs[:created_by]

    with :ok <- valid([{:title, title?(title)}, {:created_by, Prima.PersonId.person?(by)}]) do
      Arca.Repo.owned("Arca.SharedThreads.create", fn ->
        SharedThreadMembers.hold_people!([by])
        now = Arca.ServerMetaStorage.now!()
        id = Prima.UUID7.generate_id("sth")

        {1, _} =
          Arca.Repo.insert_all(SharedThread, [
            %{id: id, kind: "shared", title: title, created_by: by, created_at: now}
          ])

        :ok = SharedThreadMembers.seat!(id, by, by, now)
        {:ok, Arca.Repo.get!(SharedThread, id)}
      end)
    end
  end

  def create(%Prima.Actor{}, _attrs), do: {:error, :cross_tenant}

  @doc """
  The active pair of `by` and `other`, made for them by `by` when there is
  none: the thread and both seats in one transaction. Of two callers
  asking at once, one writes the pair and the other answers it, because
  the baseline lets one active pair hold its `pair_of`.
  """
  @spec pair(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, row()} | {:error, {:invalid, map()}} | refusal()
  def pair(%Prima.Actor{scope: :platform}, by, other) do
    two? = Prima.PersonId.person?(by) and Prima.PersonId.person?(other) and by != other

    with :ok <- valid([{:people, two?}]) do
      pair_of = [by, other] |> Enum.sort() |> Enum.join(":")

      Arca.Repo.owned("Arca.SharedThreads.pair", fn ->
        SharedThreadMembers.hold_people!([by, other])

        case active_pair(pair_of) do
          %SharedThread{} = found -> {:ok, found}
          nil -> make_pair(pair_of, by, other)
        end
      end)
    end
  end

  def pair(%Prima.Actor{}, _by, _other), do: {:error, :cross_tenant}

  # The pair is written only when no active pair holds `pair_of`; a pair
  # another transaction committed first leaves this insert a no-op, and the
  # read after it sees that pair.
  # arca:unscoped-ok a pair is no athanor's; it is written by its two people.
  defp make_pair(pair_of, by, other) do
    now = Arca.ServerMetaStorage.now!()
    id = Prima.UUID7.generate_id("sth")
    row = %{id: id, kind: "pair", pair_of: pair_of, created_by: by, created_at: now}

    case Arca.Repo.insert_all(SharedThread, [row],
           on_conflict: :nothing,
           conflict_target: {:unsafe_fragment, "(pair_of) WHERE status = 'active'"}
         ) do
      {1, _} ->
        :ok = SharedThreadMembers.seat!(id, by, by, now)
        :ok = SharedThreadMembers.seat!(id, other, by, now)
        {:ok, Arca.Repo.get!(SharedThread, id)}

      {0, _} ->
        {:ok, active_pair(pair_of)}
    end
  end

  # arca:unscoped-ok a pair is no athanor's; the active one is found by its two people.
  defp active_pair(pair_of),
    do: Arca.Repo.get_by(SharedThread, pair_of: pair_of, status: "active")

  @doc "The thread `id` names."
  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :cross_tenant | :database_error}
  # arca:unscoped-ok a shared thread is no athanor's; it is read by its id.
  def get(%Prima.Actor{scope: :platform}, id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.SharedThreads.get", fn ->
      found(Arca.Repo.get(SharedThread, id))
    end)
    |> Arca.Data.project()
  end

  def get(%Prima.Actor{}, _id), do: {:error, :cross_tenant}

  @doc """
  The threads `user_id` is seated in, active and archived, the latest
  message or birth first.
  """
  @spec list_for(Prima.Actor.t(), String.t()) ::
          {:ok, [row()]} | {:error, :cross_tenant | :database_error}
  # arca:unscoped-ok a shared thread is no athanor's; a person's are read by their seats.
  def list_for(%Prima.Actor{scope: :platform}, user_id) when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.SharedThreads.list_for", fn ->
      {:ok,
       Arca.Repo.all(
         from(t in SharedThread,
           join: m in SharedThreadMember,
           on: m.thread_id == t.id,
           where: m.user_id == ^user_id and m.status == "active",
           order_by: [desc: coalesce(t.last_message_at, t.created_at), desc: t.id]
         )
       )}
    end)
    |> Arca.Data.project()
  end

  def list_for(%Prima.Actor{}, _user_id), do: {:error, :cross_tenant}

  @doc "Give the thread `id` a new `title`; a pair has none to give."
  @spec rename(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :pair | {:invalid, map()}} | refusal()
  # arca:unscoped-ok a shared thread is no athanor's; it is renamed by its id.
  def rename(%Prima.Actor{scope: :platform}, id, title) when is_binary(id) do
    with :ok <- valid([{:title, title?(title)}]) do
      Arca.Repo.owned("Arca.SharedThreads.rename", fn ->
        case lock!(id) do
          nil ->
            {:error, :not_found}

          %SharedThread{kind: "pair"} ->
            {:error, :pair}

          %SharedThread{} ->
            {1, _} = Arca.Repo.update_all(by_id(id), set: [title: title])
            {:ok, Arca.Repo.get!(SharedThread, id)}
        end
      end)
    end
  end

  def rename(%Prima.Actor{}, _id, _title), do: {:error, :cross_tenant}

  @doc """
  Archive the thread `id`: its status, the time and one more
  `security_generation`. One archived already answers as it stands.
  """
  @spec archive(Prima.Actor.t(), String.t()) :: {:ok, row()} | {:error, :not_found} | refusal()
  # arca:unscoped-ok a shared thread is no athanor's; it is archived by its id.
  def archive(%Prima.Actor{scope: :platform}, id) when is_binary(id) do
    Arca.Repo.owned("Arca.SharedThreads.archive", fn ->
      case lock!(id) do
        nil ->
          {:error, :not_found}

        %SharedThread{status: "archived"} = thread ->
          {:ok, thread}

        %SharedThread{} ->
          now = Arca.ServerMetaStorage.now!()

          {1, _} =
            Arca.Repo.update_all(by_id(id),
              set: [status: "archived", archived_at: now],
              inc: [security_generation: 1]
            )

          {:ok, Arca.Repo.get!(SharedThread, id)}
      end
    end)
  end

  def archive(%Prima.Actor{}, _id), do: {:error, :cross_tenant}

  @doc """
  Reopen the archived thread `id`, with one more `security_generation`. One
  active already answers as it stands; a pair, once ended, stays ended.
  """
  @spec unarchive(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :pair} | refusal()
  # arca:unscoped-ok a shared thread is no athanor's; it is reopened by its id.
  def unarchive(%Prima.Actor{scope: :platform}, id) when is_binary(id) do
    Arca.Repo.owned("Arca.SharedThreads.unarchive", fn ->
      case lock!(id) do
        nil ->
          {:error, :not_found}

        %SharedThread{kind: "pair"} ->
          {:error, :pair}

        %SharedThread{status: "active"} = thread ->
          {:ok, thread}

        %SharedThread{} ->
          {1, _} =
            Arca.Repo.update_all(by_id(id),
              set: [status: "active", archived_at: nil],
              inc: [security_generation: 1]
            )

          {:ok, Arca.Repo.get!(SharedThread, id)}
      end
    end)
  end

  def unarchive(%Prima.Actor{}, _id), do: {:error, :cross_tenant}

  @doc false
  # The thread row, locked against every other writer of it until the
  # caller's transaction ends, or nil: a step inside the transactions of
  # this module and of `Arca.SharedThreadMembers` and `Arca.SharedMessages`.
  @spec lock!(String.t()) :: SharedThread.t() | nil
  # arca:unscoped-ok a shared thread is no athanor's; it is locked by its id.
  # arca:db-raise-ok a step inside the caller's transaction.
  def lock!(id) when is_binary(id) do
    by_id(id) |> QueryHelpers.for_update() |> Arca.Repo.one()
  end

  defp by_id(id), do: from(t in SharedThread, where: t.id == ^id)

  defp title?(title), do: is_binary(title) and String.trim(title) != ""

  defp valid(checks) do
    errors = for {field, false} <- checks, into: %{}, do: {field, ["is required or malformed"]}
    if map_size(errors) == 0, do: :ok, else: {:error, {:invalid, errors}}
  end

  defp found(nil), do: {:error, :not_found}
  defp found(%SharedThread{} = thread), do: {:ok, thread}
end
