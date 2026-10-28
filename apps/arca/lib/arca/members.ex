# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Members do
  @moduledoc """
  Membership rows — "user X is a member of athanor A"
  (`Arca.Schemas.Membership`).

  ## Two shapes, because a membership is the fabric that names a tenant

  Every function states which shape it is, and the shape decides where its
  athanor comes from.

    * **Inside one tenant.** `seat/3`, `find/2`, `find_invited_identifier/2`,
      `withdraw_invitation/2`, `list/2`, `count_active/1` and
      `count_seats/1` work in the athanor
      the actor's `athanor_id` names. The id comes from the actor, never
      from an argument, so a roster read or a seat written for one actor
      cannot touch another athanor's rows; an actor whose athanor is nil
      OR the empty string is `{:error, :no_athanor}` before any query
      runs. The empty string is an identity that was never resolved, the
      same thing `Sanctum.Context.build/1` refuses outright and
      `Arca.QueryHelpers.where_tenant/2` raises on — never a tenant named
      `""` — and a guard that took it would answer an empty roster where
      the refusal belongs.

    * **Across tenants.** A `"platform"` row names no athanor at all — it
      is the server's operator grant. A person's rows are read across
      every athanor to resolve which one they work in, an invitation is
      keyed on an identifier rather than on an athanor, and a deny sweeps a
      person out of every athanor at once. None of these can be filtered
      by one athanor without ceasing to do their job, so they match
      `scope: :platform` and refuse an athanor-scoped actor with
      `{:error, :cross_tenant}`.

  ## The platform grant

  The one platform grant is the installation's first person's, written by
  `grant_platform!/1` inside that person's mint (`Arca.Users.mint/4`),
  under the installation claims' order row and the member slot. No other
  function here writes a platform row.

  Nothing that belongs to Ecto crosses the boundary: a row is answered as
  a plain map (`Arca.Data`). A refusal is
  `:conflict` (the assignment index — the row is already there, so a
  caller that raced re-reads it), `{:invalid, %{field => [message]}}`,
  `:unknown_athanor`, `:athanor_archived`, `:not_found`, `:cross_tenant`,
  `:no_athanor` or `:database_error`.
  """

  import Ecto.Query

  alias Arca.QueryHelpers
  alias Arca.Schemas.{Athanor, Membership, User}

  # An identifier invitation, written or claimed, widens who reaches an
  # athanor, so its transaction first proves this member still owns its
  # slot on the database's clock (`Arca.Repo.owned/2`): a stale owner seats
  # nobody. A seat that names no identifier is a locking transaction alone.

  @type refusal :: {:error, :cross_tenant | :database_error}
  @type write_refusal ::
          {:error,
           :conflict | :unknown_athanor | {:invalid, %{atom() => [String.t()]}} | :database_error}

  @max_page 500

  @doc "The ceiling on one roster page, which is also its default."
  @spec max_page() :: pos_integer()
  def max_page, do: @max_page

  # ---- inside one tenant -----------------------------------------------------

  @doc """
  Write a membership row in the actor's athanor. `attrs` carries the
  principal (`:user_id` for an active row, `:person_identifier` for an
  invited one),
  `:scope`, `:status` and `:added_by`; the athanor is the actor's and any
  `:athanor_id` in `attrs` is ignored.

  The row also carries a foreign key, but SQLite reports a violation
  without naming it, so the changeset could not translate it. Reading the
  athanor first answers `:unknown_athanor` the same way on both adapters.

  The person an active seat names is locked first, then the athanor row,
  before the seat is written, in one `Arca.Repo.locking_transaction/2`,
  the standing order (`Arca.SecurityTransitions`). A denial or a leave
  holding the person, or a denial or an archive retiring the athanor,
  holds one of those locks, so a seat waits for it and then reads what it
  committed: a leave that found the person with no other seat is never
  overtaken by one landing elsewhere, and a seat never lands in an
  archived athanor: `{:error, :athanor_archived}`, the answer adding a
  member to one already gets. Under the same athanor lock, a group a
  declared restore froze — an active member's recovery still open — is
  refused `{:error, :recovering_from_restore}`.

  An invitation held for a person identifier (`:person_identifier`) is
  claimed by whoever proves that identity, so it widens who may sit here:
  its transaction first proves this member still owns its slot on the
  database's clock (`{:error, :not_owner}` otherwise).

  One option, `reserve:`, is the reservation a caller takes against a cap
  it holds on this athanor's seats: a zero-arity closure answering `:ok`
  or `{:error, reason}`, run inside the transaction once the person and
  the athanor row are locked and before the row is written: a concurrent
  seat in the same athanor waits for this transaction to end, so the
  closure sees every seat committed before it. It reads and writes only
  through Arca, makes no network call and publishes nothing.
  `{:error, reason}` rolls the whole transaction back, writes no row and is
  answered unchanged. An unknown option, or a `reserve:` that is not a
  zero-arity function, raises `ArgumentError`.
  """
  @spec seat(Prima.Actor.t(), map(), [{:reserve, (-> :ok | {:error, term()})}]) ::
          {:ok, map()}
          | {:error, :no_athanor | :athanor_archived | :not_owner}
          | write_refusal()
          | {:error, term()}
  def seat(actor, attrs, opts \\ [])

  def seat(%Prima.Actor{athanor_id: athanor_id}, attrs, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    reserve = reserve!(opts)

    write = fn ->
      with :ok <- hold_person(Map.get(attrs, :user_id)),
           :ok <- seatable(athanor_id),
           :ok <- not_frozen(athanor_id),
           :ok <- reserve.() do
        attrs |> defaults() |> Map.put(:athanor_id, athanor_id) |> do_insert()
      end
    end

    if is_nil(Map.get(attrs, :person_identifier)) do
      Arca.Repo.Errors.with_db_rescue("Arca.Members.seat", fn ->
        Arca.Repo.locking_transaction(fn -> write.() |> Arca.Repo.committed() end)
      end)
      |> Arca.Data.project()
    else
      Arca.Repo.owned("Arca.Members.seat", write)
    end
  end

  def seat(%Prima.Actor{}, _attrs, opts) do
    _reserve = reserve!(opts)
    {:error, :no_athanor}
  end

  # The one option `seat/3` declares; nothing else enters its transaction.
  defp reserve!(opts) do
    case Keyword.get(Keyword.validate!(opts, [:reserve]), :reserve) do
      nil ->
        fn -> :ok end

      reserve when is_function(reserve, 0) ->
        reserve

      _other ->
        raise ArgumentError, "Arca.Members.seat/3 takes reserve: as a zero-arity function"
    end
  end

  @doc "The person's ACTIVE-or-invited athanor row in the actor's athanor, if any."
  @spec find(Prima.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :no_athanor | :database_error}
  def find(%Prima.Actor{athanor_id: athanor_id}, user_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.find", fn ->
      found(
        Arca.Repo.one(
          from(m in Membership,
            where: m.user_id == ^user_id and m.scope == "athanor" and m.athanor_id == ^athanor_id,
            order_by: [asc: m.created_at, asc: m.id],
            limit: 1
          )
        )
      )
    end)
    |> Arca.Data.project()
  end

  def find(%Prima.Actor{}, _user_id), do: {:error, :no_athanor}

  @doc "The invitation this person identifier (`per_…`) holds in the actor's athanor, if any."
  @spec find_invited_identifier(Prima.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :no_athanor | :database_error}
  def find_invited_identifier(%Prima.Actor{athanor_id: athanor_id}, identifier)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(identifier) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.find_invited_identifier", fn ->
      found(
        Arca.Repo.one(
          from(m in Membership,
            where:
              m.person_identifier == ^identifier and m.athanor_id == ^athanor_id and
                m.status == "invited",
            limit: 1
          )
        )
      )
    end)
    |> Arca.Data.project()
  end

  def find_invited_identifier(%Prima.Actor{}, _identifier), do: {:error, :no_athanor}

  @doc """
  Withdraw the invitation `id` names in the actor's athanor, and answer
  the row that went. One DELETE matches the row only while it is still an
  invitation, so `{:error, :not_found}` answers an id with no invitation
  behind it: none was there, it was withdrawn already, or a first sign-in
  claimed it, which turns the invited row into that person's seat in
  place. A seat is never deleted here; it leaves only through
  `Arca.SecurityTransitions.leave_athanor/3`.
  """
  @spec withdraw_invitation(Prima.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :no_athanor | :database_error}
  def withdraw_invitation(%Prima.Actor{athanor_id: athanor_id}, id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.withdraw_invitation", fn ->
      # The status is decided by the DELETE itself, never by an earlier
      # read: a claim that commits first leaves this statement nothing to
      # match, on both adapters.
      {_count, withdrawn} =
        Arca.Repo.delete_all(
          from(m in Membership,
            where:
              m.id == ^id and m.athanor_id == ^athanor_id and m.scope == "athanor" and
                m.status == "invited",
            select: m
          )
        )

      case withdrawn do
        [%Membership{} = row] -> {:ok, row}
        _none -> {:error, :not_found}
      end
    end)
    |> Arca.Data.project()
  end

  def withdraw_invitation(%Prima.Actor{}, _id), do: {:error, :no_athanor}

  @doc """
  The actor's athanor's members — active and invited — as display rows,
  oldest first: `%{user_id, email, person_identifier, display_name, namespace, status,
  added_by, since}`. Paged with `limit:` (default and ceiling
  `max_page/0`) and `offset:`.
  """
  @spec list(Prima.Actor.t(), keyword()) ::
          {:ok, [map()]} | {:error, :no_athanor | :database_error}
  def list(actor, opts \\ [])

  def list(%Prima.Actor{athanor_id: athanor_id}, opts)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.list", fn ->
      limit = opts |> Keyword.get(:limit, @max_page) |> min(@max_page) |> max(1)
      offset = opts |> Keyword.get(:offset, 0) |> max(0)

      {:ok,
       Arca.Repo.all(
         from(m in Membership,
           left_join: u in User,
           on: u.id == m.user_id,
           where: m.athanor_id == ^athanor_id and m.scope == "athanor",
           order_by: [asc: m.created_at, asc: m.id],
           limit: ^limit,
           offset: ^offset,
           select: %{
             user_id: m.user_id,
             email: u.email,
             person_identifier: m.person_identifier,
             display_name: u.display_name,
             namespace: u.namespace,
             status: m.status,
             added_by: m.added_by,
             since: m.created_at
           }
         )
       )}
    end)
  end

  def list(%Prima.Actor{}, _opts), do: {:error, :no_athanor}

  @doc "How many ACTIVE members the actor's athanor has."
  @spec count_active(Prima.Actor.t()) ::
          {:ok, non_neg_integer()} | {:error, :no_athanor | :database_error}
  def count_active(%Prima.Actor{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.count_active", fn ->
      counted(
        from(m in Membership,
          where: m.athanor_id == ^athanor_id and m.status == "active",
          select: count(m.id)
        )
      )
    end)
  end

  def count_active(%Prima.Actor{}), do: {:error, :no_athanor}

  @doc """
  Every ACTIVE member's person id in the actor's athanor, oldest first.

  Unpaged, unlike `list/2`: this is the roster a close has to reach in
  full — a member it missed would keep a cached authorization the close
  was supposed to end — and the member cap is what bounds it.
  """
  @spec active_user_ids(Prima.Actor.t()) ::
          {:ok, [String.t()]} | {:error, :no_athanor | :database_error}
  def active_user_ids(%Prima.Actor{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.active_user_ids", fn ->
      {:ok,
       Arca.Repo.all(
         from(m in Membership,
           where:
             m.athanor_id == ^athanor_id and m.scope == "athanor" and m.status == "active" and
               not is_nil(m.user_id),
           order_by: [asc: m.created_at, asc: m.id],
           select: m.user_id
         )
       )}
    end)
  end

  def active_user_ids(%Prima.Actor{}), do: {:error, :no_athanor}

  @doc """
  Every seat the actor's athanor has handed out — active members and
  pending invitations alike, which is what the member cap bounds: an
  invitation is a seat someone will take.
  """
  @spec count_seats(Prima.Actor.t()) ::
          {:ok, non_neg_integer()} | {:error, :no_athanor | :database_error}
  def count_seats(%Prima.Actor{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.count_seats", fn ->
      counted(
        from(m in Membership,
          where: m.athanor_id == ^athanor_id and m.scope == "athanor",
          select: count(m.id)
        )
      )
    end)
  end

  def count_seats(%Prima.Actor{}), do: {:error, :no_athanor}

  # ---- across tenants --------------------------------------------------------

  @doc false
  @spec grant_platform!(String.t()) :: :ok | {:error, term()}
  # The installation's first person's platform grant, inside their mint's
  # transaction (`Arca.Users.mint/4`), which holds the order row and the
  # member slot: the one writer of a platform row. The person is held
  # first, as a seat holds them.
  # arca:db-raise-ok a transaction step: the mint that runs it rescues around its transaction.
  def grant_platform!(user_id) when is_binary(user_id) do
    :ok = hold_person(user_id)

    case %{user_id: user_id} |> defaults() |> Map.put(:scope, "platform") |> do_insert() do
      {:ok, _row} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "A membership by its own id. The athanor may be nil — a platform row names none."
  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found} | refusal()
  # arca:unscoped-ok a membership is fabric, read by its own id; the athanor may be nil (platform).
  def get(%Prima.Actor{scope: :platform}, id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.get", fn ->
      found(Arca.Repo.get(Membership, id))
    end)
    |> Arca.Data.project()
  end

  def get(%Prima.Actor{}, _id), do: {:error, :cross_tenant}

  @doc "The person's platform row, if any."
  @spec find_platform(Prima.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found} | refusal()
  # arca:unscoped-ok a platform row names no athanor by design.
  def find_platform(%Prima.Actor{scope: :platform}, user_id) when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.find_platform", fn ->
      found(
        Arca.Repo.one(
          from(m in Membership,
            where: m.user_id == ^user_id and m.scope == "platform" and is_nil(m.athanor_id),
            order_by: [asc: m.created_at, asc: m.id],
            limit: 1
          )
        )
      )
    end)
    |> Arca.Data.project()
  end

  def find_platform(%Prima.Actor{}, _user_id), do: {:error, :cross_tenant}

  @doc "Every platform row — the server's operators, as the rows say."
  @spec list_platform(Prima.Actor.t()) :: {:ok, [map()]} | refusal()
  # arca:unscoped-ok platform memberships carry no athanor by design.
  def list_platform(%Prima.Actor{scope: :platform}) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.list_platform", fn ->
      {:ok, Arca.Repo.all(from(m in Membership, where: m.scope == "platform"))}
    end)
    |> Arca.Data.project()
  end

  def list_platform(%Prima.Actor{}), do: {:error, :cross_tenant}

  @doc "Every ACTIVE row of a person — platform and athanor alike, newest first."
  @spec list_active_for_user(Prima.Actor.t(), String.t()) ::
          {:ok, [map()]} | refusal()
  # arca:unscoped-ok person-keyed by design — resolving a person's seats across athanors is the point.
  def list_active_for_user(%Prima.Actor{scope: :platform}, user_id) when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.list_active_for_user", fn ->
      {:ok,
       Arca.Repo.all(
         from(m in Membership,
           where: m.user_id == ^user_id and m.status == "active",
           order_by: [desc: m.created_at]
         )
       )}
    end)
    |> Arca.Data.project()
  end

  def list_active_for_user(%Prima.Actor{}, _user_id), do: {:error, :cross_tenant}

  # The athanors the person's invitations name, locked in id order after
  # the person, as `seat/3` locks its athanor after its person: a seat
  # into one of them that is still uncommitted holds that lock, so the
  # freeze this activation reads next is read after it, never in a
  # snapshot it then updates past.
  defp lock_invited_athanors(invited) do
    ids =
      from(m in invited, where: not is_nil(m.athanor_id), select: m.athanor_id, distinct: true)
      |> Arca.Repo.all()
      |> Enum.sort()

    from(a in Athanor, where: a.id in ^ids, order_by: [asc: a.id], select: a.id)
    |> QueryHelpers.for_update()
    |> Arca.Repo.all()
  end

  # The invitations of `invited` to the athanors `locked` holds, each a
  # group no declared restore holds frozen, read in the activating
  # transaction after those locks. An invitation to an athanor not locked
  # here stays an invitation for a later sign-in.
  defp unfrozen(invited, locked) do
    from(m in invited,
      where:
        m.athanor_id in ^locked and
          m.athanor_id not in subquery(Arca.SecurityTransitions.frozen_athanors())
    )
  end

  @doc """
  Turn every invitation held for a person identifier (`per_…`) into this
  person's active membership, and answer the athanors that changed: the
  identifier consumed, in one transaction with the person's row locked
  first, as a seat locks it, so a claim never overtakes a leave holding
  the person, and an invitation for an athanor the person already sits in
  is dropped. An invitation already activated or withdrawn is not there to
  find. An invitation to a group a declared restore froze — one with an
  active member whose recovery is still open
  (`Arca.SecurityTransitions.restore_frozen?/1`) — stays an invitation,
  read after the invitations' athanors are locked in the order `seat/3`
  locks one, and activates on a sign-in after every member has recovered.
  Seating a person widens what they reach, so the transaction first proves
  this member still owns its slot (`{:error, :not_owner}` otherwise).
  """
  @spec activate_invited_identifier(Prima.Actor.t(), String.t(), String.t(), DateTime.t()) ::
          {:ok, [String.t()]} | {:error, :not_owner} | refusal()
  # arca:unscoped-ok invited rows are identifier-keyed fabric, activated across athanors.
  def activate_invited_identifier(
        %Prima.Actor{scope: :platform},
        user_id,
        identifier,
        %DateTime{} = now
      )
      when is_binary(user_id) and is_binary(identifier) do
    invited =
      from(m in Membership,
        where:
          m.person_identifier == ^identifier and m.status == "invited" and m.scope == "athanor"
      )

    superseded =
      from(m in invited,
        where:
          m.athanor_id in subquery(
            from(a in Membership,
              where: a.user_id == ^user_id and a.scope == "athanor" and a.status == "active",
              select: a.athanor_id
            )
          )
      )

    Arca.Repo.owned("Arca.Members.activate_invited_identifier", fn ->
      :ok = hold_person(user_id)
      locked = lock_invited_athanors(invited)
      Arca.Repo.delete_all(superseded)

      {_count, athanor_ids} =
        Arca.Repo.update_all(from(m in unfrozen(invited, locked), select: m.athanor_id),
          set: [user_id: user_id, status: "active", person_identifier: nil, updated_at: now]
        )

      {:ok, athanor_ids || []}
    end)
  end

  def activate_invited_identifier(%Prima.Actor{}, _user_id, _identifier, _now),
    do: {:error, :cross_tenant}

  @doc """
  Drop every pending invitation held for a person identifier, and answer
  the athanors that were holding one.
  """
  @spec withdraw_invites_for_identifier(Prima.Actor.t(), String.t()) ::
          {:ok, [String.t()]} | refusal()
  # arca:unscoped-ok invites are identifier-keyed fabric, withdrawn across every athanor that invited.
  def withdraw_invites_for_identifier(%Prima.Actor{scope: :platform}, identifier)
      when is_binary(identifier) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.withdraw_invites_for_identifier", fn ->
      Arca.Repo.locking_transaction(fn ->
        {_count, athanor_ids} =
          Arca.Repo.delete_all(
            from(m in Membership,
              where:
                m.person_identifier == ^identifier and m.status == "invited" and
                  m.scope == "athanor",
              select: m.athanor_id
            )
          )

        athanor_ids || []
      end)
    end)
  end

  def withdraw_invites_for_identifier(%Prima.Actor{}, _identifier), do: {:error, :cross_tenant}

  @doc """
  Whether two people currently sit together in at least one ACTIVE athanor
  — active memberships in active athanors only, since an invitation is not
  a seat and an archived room is not a room.
  """
  @spec shared_athanor?(Prima.Actor.t(), String.t(), String.t()) :: {:ok, boolean()} | refusal()
  # arca:unscoped-ok whether two people share any athanor is asked across tenants by
  # design, under the platform actor alone: the query is keyed by the two people, the
  # athanor column only joins their memberships, and the answer is a boolean.
  def shared_athanor?(%Prima.Actor{scope: :platform}, user_a, user_b)
      when is_binary(user_a) and is_binary(user_b) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.shared_athanor?", fn ->
      count =
        Arca.Repo.one(
          from(a in Membership,
            join: b in Membership,
            on: a.athanor_id == b.athanor_id,
            join: ath in Athanor,
            on: ath.id == a.athanor_id,
            where:
              a.user_id == ^user_a and b.user_id == ^user_b and
                a.scope == "athanor" and b.scope == "athanor" and
                a.status == "active" and b.status == "active" and
                ath.status == "active",
            select: count(a.id)
          )
        )

      {:ok, (count || 0) > 0}
    end)
  end

  def shared_athanor?(%Prima.Actor{}, _user_a, _user_b), do: {:error, :cross_tenant}

  @doc """
  The people `user_id` sits with: everyone holding an active athanor seat
  in an ACTIVE athanor where `user_id` holds an active athanor seat too, as
  `%{user_id, display_name, email}`, each once and never `user_id`
  themself, in no particular order. The name and email come from the
  person's users row alone, never from a seat, and a seat with no users
  row is not listed. An invitation, a platform grant and an archived
  athanor are no shared room, on either side.

  One statement reads the caller's seats, their athanors and the people
  seated there, so all three are one snapshot: a seat removed before it
  excludes its athanor, and nothing that lands after it reaches the
  answer. It is not paged; the member cap of each of the caller's
  athanors bounds it.
  """
  @spec people_sharing(Prima.Actor.t(), String.t()) ::
          {:ok, [%{user_id: String.t(), display_name: String.t() | nil, email: String.t() | nil}]}
          | refusal()
  # arca:unscoped-ok who sits with a person is asked across tenants by design, under the
  # platform actor alone: every row is reached through the caller's own active seat, so the
  # statement reads nothing of an athanor the caller does not sit in. `shared_athanor?/3`
  # asks the same rule of one pair.
  def people_sharing(%Prima.Actor{scope: :platform}, user_id) when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Members.people_sharing", fn ->
      # The answer is the users rows themselves, one row per person by
      # construction: the seats only decide which rows qualify, so a person
      # seated with the caller in several athanors is listed once, whatever
      # their seats carry.
      {:ok,
       Arca.Repo.all(
         from(u in User,
           where:
             u.id != ^user_id and
               u.id in subquery(
                 from(mine in Membership,
                   join: a in Athanor,
                   on: a.id == mine.athanor_id,
                   join: m in Membership,
                   on: m.athanor_id == a.id,
                   where:
                     mine.user_id == ^user_id and mine.scope == "athanor" and
                       mine.status == "active" and a.status == "active" and
                       m.scope == "athanor" and m.status == "active",
                   select: m.user_id
                 )
               ),
           select: %{user_id: u.id, display_name: u.display_name, email: u.email}
         )
       )}
    end)
  end

  def people_sharing(%Prima.Actor{}, _user_id), do: {:error, :cross_tenant}

  # ---- internal --------------------------------------------------------------

  # People sorted by id: the order every multi-person lock takes them in.
  defp lock_people(user_ids) do
    from(u in User, where: u.id in ^user_ids, order_by: [asc: u.id])
    |> QueryHelpers.for_update()
    |> Arca.Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  # arca:unscoped-ok the athanor is the caller's clause's: `seat/3` takes it from the actor and
  # `grant_platform!/1` writes the row that names none, so this statement never chooses one.
  defp do_insert(attrs) do
    %Membership{}
    |> Membership.changeset(attrs)
    |> Arca.Repo.insert()
    |> settled()
  end

  defp defaults(attrs) do
    now = DateTime.utc_now()

    attrs
    |> Map.new()
    |> Map.put_new(:id, Prima.UUID7.generate_id("mem"))
    |> Map.put_new(:created_at, now)
    |> Map.put_new(:updated_at, now)
  end

  # The person a membership row names, locked: the first lock of the
  # standing order (`Arca.SecurityTransitions`), so a seat, a claim or a
  # grant waits for a leave or a denial holding the person, or it for them.
  # A person with no row has nothing to hold; an invitation names no
  # person.
  defp hold_person(user_id) when is_binary(user_id) do
    _held = lock_people([user_id])
    :ok
  end

  defp hold_person(_none), do: :ok

  # The athanor a seat is written into, locked: an athanor being retired
  # holds this row until it commits.
  defp seatable(athanor_id) do
    from(a in Athanor, where: a.id == ^athanor_id, select: a.status)
    |> QueryHelpers.for_update()
    |> Arca.Repo.one()
    |> case do
      nil -> {:error, :unknown_athanor}
      "archived" -> {:error, :athanor_archived}
      _active -> :ok
    end
  end

  # A group a declared restore froze admits no one new: read under the
  # athanor's lock `seatable/1` took, so of two seats racing into one
  # group, the second reads the first, and a member whose recovery is open
  # seated first freezes the group for the one that waited
  # (`Arca.SecurityTransitions.restore_frozen?/1`).
  defp not_frozen(athanor_id) do
    frozen = where(Arca.SecurityTransitions.frozen_athanors(), [m], m.athanor_id == ^athanor_id)
    if Arca.Repo.exists?(frozen), do: {:error, :recovering_from_restore}, else: :ok
  end

  defp found(nil), do: {:error, :not_found}
  defp found(%Membership{} = membership), do: {:ok, membership}

  defp counted(query), do: {:ok, Arca.Repo.one(query) || 0}

  defp settled({:ok, %Membership{} = membership}), do: {:ok, membership}
  defp settled({:error, %Ecto.Changeset{} = changeset}), do: {:error, refusal(changeset)}

  # The assignment index is the one refusal a caller acts on rather than
  # reports: the row it wanted is already there, so it re-reads it.
  defp refusal(%Ecto.Changeset{errors: errors} = changeset) do
    if unique?(errors), do: :conflict, else: Arca.Data.invalid(changeset)
  end

  defp unique?(errors) do
    Enum.any?(errors, fn {_field, {_message, meta}} -> meta[:constraint] == :unique end)
  end
end
