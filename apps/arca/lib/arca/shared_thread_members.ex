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
  written only into an active thread, by someone seated there, into a
  thread no declared restore holds (`Arca.SecurityTransitions.frozen_shared_threads/0`:
  one of its people still recovers), and while the thread's people, its
  invitations included, stay under `max_people_per_thread`
  (`Prima.Caps.check_counted/3`), each read under the thread's lock; an
  activation seats no one in a thread a restore holds, whose invitation
  waits for a later sign-in. Every write to a thread's people takes the
  thread's row lock before anything else of the thread is read, so a
  removal that commits first is read by the seat, the invitation or the
  message waiting on it. Withdrawing and removing are a person's act:
  they take the one acting and read their seat under the lock, and are
  admitted whatever the thread's status, each one delete under the
  predicate that names its row, whose row count is its answer: a
  withdrawal finds no invitation an activation already made a seat, and of
  two removals of one seat one answers it and the other `:not_found`. A
  pair gains and loses no one: its two seats are written at its birth,
  and it ends by a leave.

  A row crosses as a plain map (`Arca.Data`). A refusal is `:not_found`,
  `:archived` (the thread is archived), `:conflict` (the person is seated
  already, or the identifier invited already), `:not_member` (the one
  acting sits nowhere in the thread), `:denied` (the person a seat names
  no longer stands here), `:pair`, `:recovering_from_restore`, a cap's
  `{:limit_reached, key, cap}` or `{:cap_unverifiable, key}` (a row the
  thread already holds is `:conflict` first, since it takes no place), the
  `verify:` option's own refusal,
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

  @doc """
  Seat the person `user_id` in the thread, added by `added_by`, who sits
  there. `verify:` is a zero-arity closure run under the thread's lock,
  after every check the module doc names and before the row: `:ok`, or
  `{:error, reason}`, which writes nothing and is answered (an
  invitation's redemption reads its issuer's standing there).
  """
  @spec seat(Prima.Actor.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, row()}
          | {:error, :not_found | :archived | :conflict | {:invalid, map()} | term()}
          | refusal()
  def seat(actor, thread_id, user_id, added_by, opts \\ [])

  def seat(%Prima.Actor{scope: :platform} = actor, thread_id, user_id, added_by, opts)
      when is_binary(thread_id) and is_list(opts) do
    verify = Keyword.get(Keyword.validate!(opts, [:verify]), :verify, fn -> :ok end)

    with :ok <- valid(user_id: person?(user_id), added_by: person?(added_by)) do
      Arca.Repo.owned("Arca.SharedThreadMembers.seat", fn ->
        hold_people!([user_id])

        with :ok <- not_denied(user_id) do
          add(actor, thread_id, @seated, verify, %{
            user_id: user_id,
            status: "active",
            added_by: added_by
          })
        end
      end)
    end
  end

  def seat(%Prima.Actor{}, _thread_id, _user_id, _added_by, _opts), do: {:error, :cross_tenant}

  @doc """
  Invite the person `identifier` names (`per_…`) into the thread, added by
  `added_by`: an invitation no person holds until they sign in here.
  """
  @spec invite(Prima.Actor.t(), String.t(), String.t(), String.t()) ::
          {:ok, row()}
          | {:error, :not_found | :archived | :conflict | {:invalid, map()}}
          | refusal()
  def invite(%Prima.Actor{scope: :platform} = actor, thread_id, identifier, added_by)
      when is_binary(thread_id) do
    with :ok <- valid(person_identifier: present?(identifier), added_by: person?(added_by)) do
      Arca.Repo.owned("Arca.SharedThreadMembers.invite", fn ->
        add(actor, thread_id, @invited, fn -> :ok end, %{
          person_identifier: identifier,
          status: "invited",
          added_by: added_by
        })
      end)
    end
  end

  def invite(%Prima.Actor{}, _thread_id, _identifier, _added_by), do: {:error, :cross_tenant}

  # The row, written into the thread under its lock while the module
  # doc's checks hold, each read under that lock; a row the index already
  # holds leaves the insert a no-op.
  # arca:unscoped-ok a shared thread is no athanor's; its row is written by its thread.
  defp add(actor, thread_id, target, verify, fields) do
    with {:ok, %SharedThread{}} <- open_thread(thread_id),
         :ok <- seated(thread_id, fields.added_by),
         :ok <- not_held(thread_id, fields),
         :ok <- not_frozen(thread_id),
         :ok <- people_cap(actor, thread_id),
         :ok <- verify.() do
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

  defp open_thread(thread_id) do
    case SharedThreads.lock!(thread_id) do
      nil -> {:error, :not_found}
      %SharedThread{status: "archived"} -> {:error, :archived}
      %SharedThread{kind: "pair"} -> {:error, :pair}
      %SharedThread{} = thread -> {:ok, thread}
    end
  end

  # A seat or an invitation the thread already holds is answered
  # `:conflict` before anything is counted, read under its lock: it takes
  # no new place, so neither the cap nor a restore's hold refuses it.
  # arca:unscoped-ok a shared thread is no athanor's; its row is read by its thread and key.
  defp not_held(thread_id, %{status: "active", user_id: user_id}),
    do: if(Arca.Repo.exists?(seat_of(thread_id, user_id)), do: {:error, :conflict}, else: :ok)

  defp not_held(thread_id, %{status: "invited", person_identifier: identifier}) do
    held =
      from(m in SharedThreadMember,
        where:
          m.thread_id == ^thread_id and m.person_identifier == ^identifier and
            m.status == "invited"
      )

    if Arca.Repo.exists?(held), do: {:error, :conflict}, else: :ok
  end

  # The person a seat names stands here, read under their lock, which a
  # denial takes first: a denial that committed first refuses the seat.
  # arca:unscoped-ok a person is no athanor's; their standing is read by their id.
  defp not_denied(user_id) do
    denied = from(u in User, where: u.id == ^user_id and u.status != "active")
    if Arca.Repo.exists?(denied), do: {:error, :denied}, else: :ok
  end

  # The one adding or removing sits in the thread, read under its lock.
  defp seated(thread_id, user_id),
    do: if(seated?(thread_id, user_id), do: :ok, else: {:error, :not_member})

  @doc false
  # Whether `user_id` sits in the thread, read inside the caller's
  # transaction after it locked the thread: the seat a write by them
  # stands on (`Arca.SharedThreads`).
  @spec seated?(String.t(), String.t()) :: boolean()
  # arca:unscoped-ok a shared thread is no athanor's; a seat is read by its thread and person.
  # arca:db-raise-ok a step inside the caller's transaction.
  def seated?(thread_id, user_id) when is_binary(thread_id) and is_binary(user_id),
    do: Arca.Repo.exists?(seat_of(thread_id, user_id))

  def seated?(_thread_id, _user_id), do: false

  # A thread one of whose people still recovers from a declared restore
  # admits no one new, read under its lock, so a seat racing one into the
  # thread reads the first.
  defp not_frozen(thread_id) do
    frozen =
      where(Arca.SecurityTransitions.frozen_shared_threads(), [m], m.thread_id == ^thread_id)

    if Arca.Repo.exists?(frozen), do: {:error, :recovering_from_restore}, else: :ok
  end

  # Every row the thread has handed out, its invitations included, since
  # an invitation is a seat someone will take: counted under the thread's
  # lock, so two writes cannot both take its last place.
  # arca:unscoped-ok a shared thread is no athanor's; its rows are counted by its id.
  defp people_cap(actor, thread_id) do
    Prima.Caps.check_counted(actor, :max_people_per_thread, fn ->
      {:ok,
       Arca.Repo.one(
         from(m in SharedThreadMember, where: m.thread_id == ^thread_id, select: count(m.id))
       )}
    end)
  end

  @doc """
  Turn every invitation held for `identifier` in an active thread into the
  person `user_id`'s seat, and answer those threads' ids, sorted. An
  invitation to a thread the person already sits in is dropped; one to an
  archived thread, or to one a declared restore holds while one of its
  people recovers, stays an invitation, for a sign-in after it opens. The
  person is locked first and the invitations' threads after, in id order,
  and the restore's hold is read under those locks.
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
            from(m in invited,
              where:
                m.thread_id in ^open and
                  m.thread_id not in subquery(Arca.SecurityTransitions.frozen_shared_threads()),
              select: m.thread_id
            ),
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

  @doc """
  Withdraw the invitation `identifier` holds in the thread, as `by`, who
  sits there, and answer it.
  """
  @spec withdraw(Prima.Actor.t(), String.t(), String.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :not_member | :pair} | refusal()
  def withdraw(%Prima.Actor{scope: :platform}, thread_id, identifier, by)
      when is_binary(thread_id) and is_binary(identifier) and is_binary(by) do
    Arca.Repo.owned("Arca.SharedThreadMembers.withdraw", fn ->
      with :ok <- held_by(thread_id, by) do
        drop(
          from(m in SharedThreadMember,
            where:
              m.thread_id == ^thread_id and m.person_identifier == ^identifier and
                m.status == "invited"
          )
        )
      end
    end)
  end

  def withdraw(%Prima.Actor{}, _thread_id, _identifier, _by), do: {:error, :cross_tenant}

  # The thread locked, then `by`'s seat in it read under that lock: the
  # first step of every write that removes someone from a thread, so it
  # and a removal of `by` decide in one order. A pair loses no one but by
  # its end.
  defp held_by(thread_id, by) do
    case SharedThreads.lock!(thread_id) do
      nil -> {:error, :not_found}
      %SharedThread{kind: "pair"} -> {:error, :pair}
      %SharedThread{} -> seated(thread_id, by)
    end
  end

  @doc """
  The person `user_id` leaves the thread: their seat removed under the
  thread's lock, then the thread archived, one more
  `security_generation`, when it is a pair or no one is left seated in
  it. Answers the seat and whether the thread ended; `:not_found` when
  they sit there no longer, writing nothing.
  """
  @spec leave(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, %{seat: row(), ended: boolean()}} | {:error, :not_found} | refusal()
  def leave(%Prima.Actor{scope: :platform}, thread_id, user_id)
      when is_binary(thread_id) and is_binary(user_id) do
    Arca.Repo.owned("Arca.SharedThreadMembers.leave", fn ->
      case SharedThreads.lock!(thread_id) do
        nil ->
          {:error, :not_found}

        %SharedThread{} = thread ->
          with {:ok, seat} <- drop(seat_of(thread_id, user_id)) do
            {:ok, %{seat: seat, ended: ended(thread)}}
          end
      end
    end)
  end

  def leave(%Prima.Actor{}, _thread_id, _user_id), do: {:error, :cross_tenant}

  # The thread the leave holds, archived when it is an active pair or no
  # one is seated in it any longer.
  # arca:unscoped-ok a shared thread is no athanor's; it is archived by its id.
  defp ended(%SharedThread{status: "active", id: id} = thread) do
    if thread.kind == "pair" or
         not Arca.Repo.exists?(
           from(m in SharedThreadMember, where: m.thread_id == ^id and m.status == "active")
         ) do
      case Arca.Repo.update_all(
             from(t in SharedThread, where: t.id == ^id and t.status == "active"),
             set: [status: "archived", archived_at: Arca.ServerMetaStorage.now!()],
             inc: [security_generation: 1]
           ) do
        {1, _} -> true
        {0, _} -> false
      end
    else
      false
    end
  end

  defp ended(%SharedThread{}), do: false

  @doc """
  Remove the person `user_id`'s seat from the thread, as `by`, who sits
  there, and answer it: the thread locked first, so a seat, an invitation
  or a message waiting on the lock reads the removal.
  """
  @spec remove(Prima.Actor.t(), String.t(), String.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :not_member | :pair} | refusal()
  def remove(%Prima.Actor{scope: :platform}, thread_id, user_id, by)
      when is_binary(thread_id) and is_binary(user_id) and is_binary(by) do
    Arca.Repo.owned("Arca.SharedThreadMembers.remove", fn ->
      with :ok <- held_by(thread_id, by), do: drop(seat_of(thread_id, user_id))
    end)
  end

  def remove(%Prima.Actor{}, _thread_id, _user_id, _by), do: {:error, :cross_tenant}

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

  @doc """
  Whether the people `user_a` and `user_b` are both seated in one active
  thread: what a pair asks of two people (`Sanctum.SharedThreads`), here
  for the sentence it answers, and again inside the pair's transaction
  (`together!/2`), where it decides.
  """
  @spec together?(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, boolean()} | {:error, :cross_tenant | :database_error}
  def together?(%Prima.Actor{scope: :platform}, user_a, user_b)
      when is_binary(user_a) and is_binary(user_b) do
    Arca.Repo.Errors.with_db_rescue("Arca.SharedThreadMembers.together?", fn ->
      {:ok, together!(user_a, user_b)}
    end)
  end

  def together?(%Prima.Actor{}, _user_a, _user_b), do: {:error, :cross_tenant}

  @doc false
  # `together?/3` inside the caller's transaction: the pair's, after it
  # locked the two people.
  @spec together!(String.t(), String.t()) :: boolean()
  # arca:unscoped-ok a shared thread is no athanor's; two people's seats are read by their ids.
  # arca:db-raise-ok a step inside the caller's transaction.
  def together!(user_a, user_b) when is_binary(user_a) and is_binary(user_b) do
    Arca.Repo.exists?(
      from(a in SharedThreadMember,
        join: b in SharedThreadMember,
        on: b.thread_id == a.thread_id,
        join: t in SharedThread,
        on: t.id == a.thread_id,
        where:
          a.user_id == ^user_a and a.status == "active" and b.user_id == ^user_b and
            b.status == "active" and t.status == "active"
      )
    )
  end

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
