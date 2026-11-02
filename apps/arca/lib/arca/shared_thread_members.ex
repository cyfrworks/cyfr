# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SharedThreadMembers do
  @moduledoc """
  The people of a shared thread (`Arca.Schemas.SharedThreadMember`): a
  person's seat (`active`, naming `user_id`), or an invitation held for a
  person identifier (`invited`, naming `person_identifier`) until that
  person signs in here and `activate/3` turns it into their seat. A thread
  holds one seat per person and one invitation per identifier, which the
  baseline's partial unique indexes keep on both adapters. Who may seat,
  invite, withdraw or remove someone is `Sanctum.SharedThreads`'.

  ## The first argument

  Every function matches `scope: :platform` and refuses any other actor
  with `{:error, :cross_tenant}`: a shared thread is no athanor's.

  ## Writes

  A seat or an invitation widens who reads a thread, so every write runs
  under this member's slot (`Arca.Repo.owned/2`; `:not_owner` once another
  member holds it). A write that seats a person locks that person's row
  first and the thread after it, the order a person's standing
  transitions take (`Arca.SecurityTransitions`), so a seat never lands
  beside a transition holding the person. A seat or an invitation is
  written only into an active thread, read under the thread's lock;
  withdrawing and removing are admitted whatever the thread's status, each
  one delete under the predicate that names its row, whose row count is
  its answer: a withdrawal finds no invitation an activation already made
  a seat, and of two removals of one seat one answers it and the other
  `:not_found`.

  A row crosses as a plain map (`Arca.Data`). A refusal is `:not_found`,
  `:archived` (the thread is archived), `:conflict` (the person is seated
  already, or the identifier invited already),
  `{:invalid, %{field => [message]}}`, `:cross_tenant`, `:not_owner` or
  `:database_error`.
  """

  import Ecto.Query

  alias Arca.QueryHelpers
  alias Arca.Schemas.{SharedThread, SharedThreadMember, User}
  alias Arca.SharedThreads

  @typedoc "A seat or an invitation, as a plain map."
  @type row :: map()

  @type refusal :: {:error, :cross_tenant | :not_owner | :database_error}

  @seated "(thread_id, user_id) WHERE status = 'active'"
  @invited "(thread_id, person_identifier) WHERE status = 'invited'"

  @doc "Seat the person `user_id` in the thread, added by `added_by`."
  @spec seat(Prima.Actor.t(), String.t(), String.t(), String.t()) ::
          {:ok, row()}
          | {:error, :not_found | :archived | :conflict | {:invalid, map()}}
          | refusal()
  def seat(%Prima.Actor{scope: :platform}, thread_id, user_id, added_by)
      when is_binary(thread_id) do
    with :ok <- valid(user_id: person?(user_id), added_by: person?(added_by)) do
      Arca.Repo.owned("Arca.SharedThreadMembers.seat", fn ->
        hold_people!([user_id])

        add(thread_id, @seated, %{user_id: user_id, status: "active", added_by: added_by})
      end)
    end
  end

  def seat(%Prima.Actor{}, _thread_id, _user_id, _added_by), do: {:error, :cross_tenant}

  @doc """
  Invite the person `identifier` names (`per_…`) into the thread, added by
  `added_by`: an invitation no person holds until they sign in here.
  """
  @spec invite(Prima.Actor.t(), String.t(), String.t(), String.t()) ::
          {:ok, row()}
          | {:error, :not_found | :archived | :conflict | {:invalid, map()}}
          | refusal()
  def invite(%Prima.Actor{scope: :platform}, thread_id, identifier, added_by)
      when is_binary(thread_id) do
    with :ok <- valid(person_identifier: present?(identifier), added_by: person?(added_by)) do
      Arca.Repo.owned("Arca.SharedThreadMembers.invite", fn ->
        add(thread_id, @invited, %{
          person_identifier: identifier,
          status: "invited",
          added_by: added_by
        })
      end)
    end
  end

  def invite(%Prima.Actor{}, _thread_id, _identifier, _added_by), do: {:error, :cross_tenant}

  # The row, written into the thread when it is active, under its lock; a
  # row the index already holds leaves the insert a no-op.
  # arca:unscoped-ok a shared thread is no athanor's; its row is written by its thread.
  defp add(thread_id, target, fields) do
    case SharedThreads.lock!(thread_id) do
      nil ->
        {:error, :not_found}

      %SharedThread{status: "archived"} ->
        {:error, :archived}

      %SharedThread{} ->
        row =
          Map.merge(fields, %{
            id: Prima.UUID7.generate_id("stm"),
            thread_id: thread_id,
            created_at: Arca.ServerMetaStorage.now!()
          })

        case Arca.Repo.insert_all(SharedThreadMember, [row],
               on_conflict: :nothing,
               conflict_target: {:unsafe_fragment, target}
             ) do
          {1, _} -> {:ok, Arca.Repo.get!(SharedThreadMember, row.id)}
          {0, _} -> {:error, :conflict}
        end
    end
  end

  @doc """
  Turn every invitation held for `identifier` in an active thread into the
  person `user_id`'s seat, and answer those threads' ids, sorted. An
  invitation to a thread the person already sits in is dropped; one to an
  archived thread stays an invitation. The person is locked first and the
  invitations' threads after, in id order.
  """
  @spec activate(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, {:invalid, map()}} | refusal()
  # arca:unscoped-ok invitations are keyed by identifier, activated in every thread that holds one.
  def activate(%Prima.Actor{scope: :platform}, user_id, identifier) do
    with :ok <- valid(user_id: person?(user_id), person_identifier: present?(identifier)) do
      invited =
        from(m in SharedThreadMember,
          where: m.person_identifier == ^identifier and m.status == "invited"
        )

      Arca.Repo.owned("Arca.SharedThreadMembers.activate", fn ->
        hold_people!([user_id])
        open = lock_open_threads(invited)

        seated =
          from(m in SharedThreadMember,
            where: m.user_id == ^user_id and m.status == "active",
            select: m.thread_id
          )

        Arca.Repo.delete_all(where(invited, [m], m.thread_id in subquery(seated)))

        {_count, ids} =
          Arca.Repo.update_all(
            from(m in invited, where: m.thread_id in ^open, select: m.thread_id),
            set: [user_id: user_id, person_identifier: nil, status: "active"]
          )

        {:ok, Enum.sort(ids || [])}
      end)
    end
  end

  def activate(%Prima.Actor{}, _user_id, _identifier), do: {:error, :cross_tenant}

  # The active threads the invitations name, locked in id order.
  # arca:unscoped-ok a shared thread is no athanor's; these are locked by the invitations naming them.
  defp lock_open_threads(invited) do
    from(t in SharedThread,
      where: t.id in subquery(select(invited, [m], m.thread_id)) and t.status == "active",
      order_by: [asc: t.id],
      select: t.id
    )
    |> QueryHelpers.for_update()
    |> Arca.Repo.all()
  end

  @doc "Withdraw the invitation `identifier` holds in the thread, and answer it."
  @spec withdraw(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found} | refusal()
  def withdraw(%Prima.Actor{scope: :platform}, thread_id, identifier)
      when is_binary(thread_id) and is_binary(identifier) do
    Arca.Repo.owned("Arca.SharedThreadMembers.withdraw", fn ->
      drop(
        from(m in SharedThreadMember,
          where:
            m.thread_id == ^thread_id and m.person_identifier == ^identifier and
              m.status == "invited"
        )
      )
    end)
  end

  def withdraw(%Prima.Actor{}, _thread_id, _identifier), do: {:error, :cross_tenant}

  @doc "Remove the person `user_id`'s seat from the thread, and answer it."
  @spec remove(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found} | refusal()
  def remove(%Prima.Actor{scope: :platform}, thread_id, user_id)
      when is_binary(thread_id) and is_binary(user_id) do
    Arca.Repo.owned("Arca.SharedThreadMembers.remove", fn ->
      drop(seat_of(thread_id, user_id))
    end)
  end

  def remove(%Prima.Actor{}, _thread_id, _user_id), do: {:error, :cross_tenant}

  # One delete of the row `query` names, under the predicate that names
  # it: its row count is the answer. A row an activation or another
  # removal changed or deleted first no longer matches, so it is answered
  # `:not_found` and left as it stands. The thread's indexes let at most
  # one row match.
  # arca:unscoped-ok a shared thread is no athanor's; the row is deleted by its thread and key.
  defp drop(query) do
    case Arca.Repo.delete_all(select(query, [m], m)) do
      {1, [row]} -> {:ok, row}
      {0, _} -> {:error, :not_found}
    end
  end

  @doc "The person `user_id`'s seat in the thread."
  @spec find(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :cross_tenant | :database_error}
  # arca:unscoped-ok a shared thread is no athanor's; a seat is read by its thread and person.
  def find(%Prima.Actor{scope: :platform}, thread_id, user_id)
      when is_binary(thread_id) and is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.SharedThreadMembers.find", fn ->
      case Arca.Repo.one(seat_of(thread_id, user_id)) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
    |> Arca.Data.project()
  end

  def find(%Prima.Actor{}, _thread_id, _user_id), do: {:error, :cross_tenant}

  @doc "The thread's seats and invitations, oldest first."
  @spec list(Prima.Actor.t(), String.t()) ::
          {:ok, [row()]} | {:error, :cross_tenant | :database_error}
  # arca:unscoped-ok a shared thread is no athanor's; its people are read by its id.
  def list(%Prima.Actor{scope: :platform}, thread_id) when is_binary(thread_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.SharedThreadMembers.list", fn ->
      {:ok,
       Arca.Repo.all(
         from(m in SharedThreadMember,
           where: m.thread_id == ^thread_id,
           order_by: [asc: m.created_at, asc: m.id]
         )
       )}
    end)
    |> Arca.Data.project()
  end

  def list(%Prima.Actor{}, _thread_id), do: {:error, :cross_tenant}

  @doc false
  # A seat written inside the caller's transaction, which locked the
  # person and made the thread: a thread's first seats
  # (`Arca.SharedThreads.create/2` and `pair/3`).
  @spec seat!(String.t(), String.t(), String.t(), DateTime.t()) :: :ok
  # arca:unscoped-ok a shared thread is no athanor's; its first seats are written by its id.
  # arca:db-raise-ok a step inside the caller's transaction.
  def seat!(thread_id, user_id, added_by, %DateTime{} = now) do
    {1, _} =
      Arca.Repo.insert_all(SharedThreadMember, [
        %{
          id: Prima.UUID7.generate_id("stm"),
          thread_id: thread_id,
          user_id: user_id,
          status: "active",
          added_by: added_by,
          created_at: now
        }
      ])

    :ok
  end

  @doc false
  # The people a write seats, locked in id order inside the caller's
  # transaction: the first lock of the standing order. A person with no
  # row has nothing to hold.
  @spec hold_people!([String.t()]) :: :ok
  # arca:unscoped-ok a person is no athanor's; people are locked by their own ids.
  # arca:db-raise-ok a step inside the caller's transaction.
  def hold_people!(user_ids) when is_list(user_ids) do
    from(u in User, where: u.id in ^user_ids, order_by: [asc: u.id], select: u.id)
    |> QueryHelpers.for_update()
    |> Arca.Repo.all()

    :ok
  end

  defp seat_of(thread_id, user_id) do
    from(m in SharedThreadMember,
      where: m.thread_id == ^thread_id and m.user_id == ^user_id and m.status == "active"
    )
  end

  defp person?(id), do: Prima.PersonId.person?(id)
  defp present?(value), do: is_binary(value) and value != ""

  defp valid(checks) do
    errors = for {field, false} <- checks, into: %{}, do: {field, ["is required or malformed"]}
    if map_size(errors) == 0, do: :ok, else: {:error, {:invalid, errors}}
  end
end
