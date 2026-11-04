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
  athanor-scoped actor can name one, and its people are read across
  athanors.

  ## Writes

  A thread and its seats widen who reads what is said in it, so every
  write runs under this member's slot (`Arca.Repo.owned/2`; `:not_owner`
  once another member holds it). The people a write seats are locked first
  and the thread after them, the order a person's standing transitions
  take (`Arca.SecurityTransitions`). A rename, an archive and a reopening
  take the caller and read their seat after the thread's lock, in the
  transaction that writes, so a removal that committed first refuses them.
  A creation and a reopening count the threads its
  creator made that stand active against `max_shared_threads_per_person`,
  and a new pair the active pairs each of its two sits in against
  `max_pairs_per_person`, under those people's locks
  (`Prima.Caps.check_counted/3`); a pair found is not counted. Renaming,
  archiving and reopening
  each lock the thread, then make one write conditional on its kind and
  status, whose row count is its answer; archiving or reopening a thread
  raises its `security_generation` by one in the same statement.

  A row crosses as a plain map (`Arca.Data`). A refusal is `:not_found`,
  `:pair` (a pair has no title and stays ended once archived),
  `:not_member` (the caller sits nowhere in the thread), `:not_together`,
  `{:invalid, %{field => [message]}}`, a cap's `{:limit_reached, key, cap}`
  or `{:cap_unverifiable, key}`, `:cross_tenant`, `:not_owner` or
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
  def create(%Prima.Actor{scope: :platform} = actor, attrs) when is_map(attrs) do
    title = attrs[:title]
    by = attrs[:created_by]

    with :ok <- valid([{:title, title?(title)}, {:created_by, Prima.PersonId.person?(by)}]) do
      Arca.Repo.owned("Arca.SharedThreads.create", fn ->
        SharedThreadMembers.hold_people!([by])

        with :ok <- Prima.Caps.check_counted(actor, :max_shared_threads_per_person, created(by)) do
          now = Arca.ServerMetaStorage.now!()
          id = Prima.UUID7.generate_id("sth")

          {1, _} =
            Arca.Repo.insert_all(SharedThread, [
              %{id: id, kind: "shared", title: title, created_by: by, created_at: now}
            ])

          :ok = SharedThreadMembers.seat!(id, by, by, now)
          {:ok, Arca.Repo.get!(SharedThread, id)}
        end
      end)
    end
  end

  def create(%Prima.Actor{}, _attrs), do: {:error, :cross_tenant}

  @doc """
  The active pair of `by` and `other`, made for them by `by` when there is
  none: the thread and both seats in one transaction, found or made only
  while the two sit together in an active thread (`:not_together`
  otherwise): the two people locked, then every active thread they share,
  in id order, then their seats read again, so a removal, a leave or a
  denial of either seat waits for the pair or is read by it. Of two callers
  asking at once, one writes the pair and the other answers it, because
  the baseline lets one active pair hold its `pair_of`.
  """
  @spec pair(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, row()} | {:error, :not_together | {:invalid, map()}} | refusal()
  def pair(%Prima.Actor{scope: :platform} = actor, by, other) do
    two? = Prima.PersonId.person?(by) and Prima.PersonId.person?(other) and by != other

    with :ok <- valid([{:people, two?}]) do
      pair_of = [by, other] |> Enum.sort() |> Enum.join(":")

      Arca.Repo.owned("Arca.SharedThreads.pair", fn ->
        SharedThreadMembers.hold_people!([by, other])
        SharedThreadMembers.lock_shared!(by, other)

        if SharedThreadMembers.together!(by, other),
          do: found_or_made(actor, pair_of, by, other),
          else: {:error, :not_together}
      end)
    end
  end

  def pair(%Prima.Actor{}, _by, _other), do: {:error, :cross_tenant}

  defp found_or_made(actor, pair_of, by, other) do
    case active_pair(pair_of) do
      %SharedThread{} = found ->
        {:ok, found}

      nil ->
        with :ok <- pairs_cap(actor, by),
             :ok <- pairs_cap(actor, other),
             do: make_pair(pair_of, by, other)
    end
  end

  # The threads `by` made that stand active, counted under their lock.
  # arca:unscoped-ok a shared thread is no athanor's; a person's are counted by their creator.
  defp created(by) do
    fn ->
      {:ok,
       Arca.Repo.one(
         from(t in SharedThread,
           where: t.created_by == ^by and t.kind == "shared" and t.status == "active",
           select: count(t.id)
         )
       )}
    end
  end

  # The active pairs `user_id` sits in, counted under their lock.
  # arca:unscoped-ok a pair is no athanor's; a person's are counted by their seats.
  defp pairs_cap(actor, user_id) do
    Prima.Caps.check_counted(actor, :max_pairs_per_person, fn ->
      {:ok,
       Arca.Repo.one(
         from(t in SharedThread,
           join: m in SharedThreadMember,
           on: m.thread_id == t.id,
           where:
             t.kind == "pair" and t.status == "active" and m.user_id == ^user_id and
               m.status == "active",
           select: count(t.id)
         )
       )}
    end)
  end

  # The pair is written only when no active pair holds `pair_of`; a pair
  # another transaction committed first leaves this insert a no-op, and the
  # read after it answers that pair.
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
        # The pair another transaction committed first, unless it was
        # archived since: then this one is made after all.
        case active_pair(pair_of) do
          %SharedThread{} = found -> {:ok, found}
          nil -> make_pair(pair_of, by, other)
        end
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

  @doc """
  Give the thread `id` a new `title`, as `by`, who sits in it; a pair has
  none to give.
  """
  @spec rename(Prima.Actor.t(), String.t(), String.t(), String.t()) ::
          {:ok, row()}
          | {:error, :not_found | :not_member | :pair | {:invalid, map()}}
          | refusal()
  def rename(%Prima.Actor{scope: :platform}, id, by, title) when is_binary(id) do
    with :ok <- valid([{:title, title?(title)}, {:by, Prima.PersonId.person?(by)}]) do
      Arca.Repo.owned("Arca.SharedThreads.rename", fn ->
        transition(id, by, dynamic([t], t.kind == "shared"), [set: [title: title]], fn
          %SharedThread{kind: "pair"} -> {:error, :pair}
        end)
      end)
    end
  end

  def rename(%Prima.Actor{}, _id, _by, _title), do: {:error, :cross_tenant}

  @doc """
  Archive the thread `id`, as `by`, who sits in it: its status, the time
  and one more `security_generation`. One archived already answers as it
  stands.
  """
  @spec archive(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :not_member} | refusal()
  def archive(%Prima.Actor{scope: :platform}, id, by) when is_binary(id) do
    with :ok <- valid([{:by, Prima.PersonId.person?(by)}]) do
      Arca.Repo.owned("Arca.SharedThreads.archive", fn ->
        changes = [
          set: [status: "archived", archived_at: Arca.ServerMetaStorage.now!()],
          inc: [security_generation: 1]
        ]

        transition(id, by, dynamic([t], t.status == "active"), changes, fn
          %SharedThread{status: "archived"} = thread -> {:ok, thread}
        end)
      end)
    end
  end

  def archive(%Prima.Actor{}, _id, _by), do: {:error, :cross_tenant}

  @doc """
  Reopen the archived thread `id`, as `by`, who still sits in it, with one
  more `security_generation`, while its creator stays under
  `max_shared_threads_per_person`, counted as a creation counts it, under
  the creator's lock and then the thread's. One active already answers as
  it stands; a pair, once ended, stays ended.
  """
  @spec unarchive(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :not_member | :pair} | refusal()
  def unarchive(%Prima.Actor{scope: :platform} = actor, id, by) when is_binary(id) do
    with :ok <- valid([{:by, Prima.PersonId.person?(by)}]) do
      Arca.Repo.owned("Arca.SharedThreads.unarchive", fn ->
        case creator(id) do
          nil ->
            {:error, :not_found}

          creator ->
            SharedThreadMembers.hold_people!(Enum.uniq([creator, by]))
            changes = [set: [status: "active", archived_at: nil], inc: [security_generation: 1]]
            reopenable = dynamic([t], t.kind == "shared" and t.status == "archived")

            counted = fn ->
              Prima.Caps.check_counted(actor, :max_shared_threads_per_person, created(creator))
            end

            transition(
              id,
              by,
              reopenable,
              changes,
              fn
                %SharedThread{kind: "pair"} -> {:error, :pair}
                %SharedThread{status: "active"} = thread -> {:ok, thread}
              end,
              counted
            )
        end
      end)
    end
  end

  def unarchive(%Prima.Actor{}, _id, _by), do: {:error, :cross_tenant}

  # Whose thread it is, which no write changes: the lock a reopening takes
  # before the thread's, so its count and a creation's serialize.
  # arca:unscoped-ok a shared thread is no athanor's; its creator is read by its id.
  defp creator(id), do: Arca.Repo.one(from(t in by_id(id), select: t.created_by))

  # The thread locked, `by`'s seat in it read under that lock, then one
  # write conditional on `condition`, whose row count is the answer: the
  # row it changed, or, when the locked row did not match, `unchanged`'s
  # answer for that row. `counted` is asked, under the same lock, only of
  # a row the write would change. No row is `:not_found`; `by` seated
  # nowhere in it is `:not_member`. The lock holds the row as it was read
  # until the transaction ends, so the reads and the write agree on it,
  # and a removal of `by` that committed first is read here.
  # arca:unscoped-ok a shared thread is no athanor's; it is changed by its id.
  defp transition(id, by, condition, changes, unchanged, counted \\ fn -> :ok end) do
    with %SharedThread{} = thread <- lock!(id) || {:error, :not_found},
         true <- SharedThreadMembers.seated?(id, by) || {:error, :not_member} do
      changing = from(t in by_id(id), where: ^condition)

      if Arca.Repo.exists?(changing) do
        with :ok <- counted.() do
          case Arca.Repo.update_all(changing, changes) do
            {1, _} -> {:ok, Arca.Repo.get!(SharedThread, id)}
            {0, _} -> unchanged.(thread)
          end
        end
      else
        unchanged.(thread)
      end
    end
  end

  @doc false
  # The thread row, locked against every other writer of it until the
  # caller's transaction ends, or nil: a step inside the transactions of
  # this module and of `Arca.SharedThreadMembers` that change a thread or
  # write a seat or an invitation into it.
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
