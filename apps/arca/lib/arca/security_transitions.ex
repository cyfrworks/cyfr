# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SecurityTransitions do
  @moduledoc """
  The four standing transitions — deny and allow a person, archive and
  reopen an estate — each as ONE transaction over every row it must
  change, or nothing.

  A transition changes a standing and retires what that standing issued:
  a denial marks the person denied, archives their own estate, every
  frozen estate they sit in and every group they leave empty, removes
  their memberships, the invitations their address still holds and their
  thread follows, deletes their sessions and revokes the keys they created
  and the keys of every estate it archives. An archive revokes the
  estate's keys with it. Each commits together or not at all: a statement
  that fails rolls the whole transition back and the caller is answered
  the failure, so a denial can never report success with a credential of
  the person still standing. An allow restores the person's standing and
  their own estate and seat and nothing else; a reopen restores the
  estate and nothing else. Neither un-revokes, re-creates or re-seats
  anything the retirement took.

  Every real change of a standing raises the row's `security_generation`
  in the same statement. A credential is issued only against the
  generation its context read (`Arca.SecurityTransitions.Issuance`), so a
  context read before a retirement cannot issue after the restore.

  ## Lock order

  Every transition, and every credential issuance, takes its row locks in
  one order: any global cap lock the operation needs, people sorted by id,
  estates sorted by id, then memberships, invitations and follows, then
  sessions, then API keys. A transition taking only a suffix of that order
  never goes back for an earlier lock. On PostgreSQL the order is the
  deadlock rule; on SQLite the write lock every transaction takes at entry is the lock
  and the order is code order (`Arca.Repo.locking_transaction/2`).

  A denial computes the estates it touches from the person's memberships,
  locks them, then locks the memberships and computes the set again, and
  once more after the caller's policy, right before it writes. A set that
  moved in between (a seat taken while the estates were being locked, or
  while the policy was asked) rolls the attempt back, because the estate
  locks cannot be taken after the membership locks; the transition runs
  again, three times at most, and then answers `{:error, :conflict}`. It
  never continues on a partial view. A seat into an estate the denial
  holds waits for it (`Arca.Members.seat/2` locks the estate first).

  ## The caller's decision

  `verify:` is the caller's policy, asked once every lock is held and
  before anything is written. It is handed plain maps of the locked rows
  (never a changeset or a row it could write back) and answers `:ok` or
  `{:error, reason}`, which rolls the transition back with that reason.
  What it may consult with the transaction open is the store itself —
  a cap count, say — and nothing outside it: no network, no filesystem,
  no broadcast.

  ## The answer

  `{:ok, change}` only after commit. `change` is the committed data the
  caller announces from: the session hashes each DELETE returned, the key
  ids each UPDATE returned, the estates archived or reopened with their
  new generations, the memberships removed, invitations withdrawn and
  seats restored, the members of each archived estate and the person's
  generation. Refusals: `:not_found`, `:dangling_personal_athanor` (a
  person's own-estate pointer names no row), `:conflict`,
  `:postcondition_failed`, `:cross_tenant`, `:database_error`, or the
  callback's own reason.
  """

  import Ecto.Query

  alias Arca.QueryHelpers
  alias Arca.Schemas.{ApiKey, Athanor, Membership, Session, ThreadSubscription, User}
  alias Arca.SecurityTransitions.Projection

  @attempts 3

  @typedoc "The caller's policy over the locked rows."
  @type verify :: (map() -> :ok | {:error, term()})

  @typedoc "What a committed transition changed."
  @type change :: %{
          required(:transitioned) => boolean(),
          required(:user) => map() | nil,
          required(:user_generation) => pos_integer() | nil,
          required(:athanor_generations) => %{String.t() => pos_integer()},
          required(:athanors) => [map()],
          required(:archived_athanor_ids) => [String.t()],
          required(:reopened_athanor_ids) => [String.t()],
          required(:revoked_session_hashes) => [binary()],
          required(:revoked_api_key_ids) => [String.t()],
          required(:removed_membership_ids) => [String.t()],
          required(:removed_memberships) => [map()],
          required(:withdrawn_invitations) => [map()],
          required(:seated_membership_ids) => [String.t()],
          required(:member_user_ids) => %{String.t() => [String.t()]},
          required(:unfollowed) => non_neg_integer()
        }

  @doc """
  Deny the person `user_id` on this server, with everything a denial
  retires (see the module doc). A person already denied is denied again:
  nothing moves their generation, and the retirement is re-run and its
  postconditions checked, so a retry finishes what a failure left.
  """
  @spec deny_user(Cyfr.Actor.t(), String.t(), keyword()) :: {:ok, change()} | {:error, term()}
  def deny_user(%Cyfr.Actor{scope: :platform, system: true}, user_id, opts)
      when is_binary(user_id) and user_id != "" and is_list(opts) do
    verify = Keyword.fetch!(opts, :verify)
    run("Arca.SecurityTransitions.deny_user", fn -> deny(user_id, verify) end)
  end

  def deny_user(%Cyfr.Actor{}, _user_id, _opts), do: {:error, :cross_tenant}

  @doc """
  Restore the person `user_id`: their standing, their own estate when it
  is archived, and their seat in it. Sessions, keys, group seats and
  invitations the denial took stay taken.
  """
  @spec allow_user(Cyfr.Actor.t(), String.t(), keyword()) :: {:ok, change()} | {:error, term()}
  def allow_user(%Cyfr.Actor{scope: :platform, system: true}, user_id, opts)
      when is_binary(user_id) and user_id != "" and is_list(opts) do
    verify = Keyword.fetch!(opts, :verify)
    run("Arca.SecurityTransitions.allow_user", fn -> allow(user_id, verify) end)
  end

  def allow_user(%Cyfr.Actor{}, _user_id, _opts), do: {:error, :cross_tenant}

  @doc """
  Archive the estate `athanor_id` and revoke its keys. An estate already
  archived keeps its generation; its keys are revoked again and checked.
  """
  @spec archive_athanor(Cyfr.Actor.t(), String.t(), keyword()) ::
          {:ok, change()} | {:error, term()}
  def archive_athanor(%Cyfr.Actor{scope: :platform, system: true}, athanor_id, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_list(opts) do
    verify = Keyword.fetch!(opts, :verify)
    run("Arca.SecurityTransitions.archive_athanor", fn -> archive(athanor_id, verify) end)
  end

  def archive_athanor(%Cyfr.Actor{}, _athanor_id, _opts), do: {:error, :cross_tenant}

  @doc """
  Reopen the archived estate `athanor_id`. Its revoked keys stay revoked.
  An estate already active is answered unchanged.
  """
  @spec unarchive_athanor(Cyfr.Actor.t(), String.t(), keyword()) ::
          {:ok, change()} | {:error, term()}
  def unarchive_athanor(%Cyfr.Actor{scope: :platform, system: true}, athanor_id, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_list(opts) do
    verify = Keyword.fetch!(opts, :verify)
    run("Arca.SecurityTransitions.unarchive_athanor", fn -> unarchive(athanor_id, verify) end)
  end

  def unarchive_athanor(%Cyfr.Actor{}, _athanor_id, _opts), do: {:error, :cross_tenant}

  # ---- the runner ------------------------------------------------------------

  # A raised database error rolls the transaction back and answers
  # `:database_error`; a set that moved between planning and locking runs
  # the whole transaction again, `@attempts` times at most.
  defp run(tag, body) do
    tag
    |> Arca.Repo.Errors.with_db_rescue(fn -> attempt(body, @attempts) end)
    |> Arca.Data.project()
  end

  defp attempt(_body, 0), do: {:error, :conflict}

  defp attempt(body, left) do
    case Arca.Repo.locking_transaction(body) do
      {:error, :set_changed} -> attempt(body, left - 1)
      other -> other
    end
  end

  defp decide(verify, projection) do
    case verify.(projection) do
      :ok -> :ok
      {:error, _reason} = refusal -> refusal
    end
  end

  # ---- deny ------------------------------------------------------------------

  defp deny(user_id, verify) do
    result =
      with {:ok, user} <- lock_user(user_id),
           planned = estates_of(user, unlocked_rows(user_id)),
           athanors = lock_athanors(planned),
           :ok <- personal_present(user, athanors),
           rows = lock_person_rows(user_id),
           :ok <- same_set(planned, estates_of(user, rows)),
           peers = lock_peers(user_id, group_ids(athanors)),
           invitations = lock_invitations(user.email),
           retire = to_retire(user, athanors, rows, peers),
           :ok <-
             decide(verify, %{
               transition: :deny_user,
               user: Projection.user(user),
               athanors: athanors |> Map.values() |> Enum.map(&Projection.athanor/1),
               memberships: Enum.map(rows, &Projection.membership/1),
               invitations: Enum.map(invitations, &Projection.membership/1),
               archive: retire
             }),
           # Asked again after the policy, right before the first write, so
           # the set the policy was shown is the set the statements act on.
           :ok <- same_set(planned, estates_of(user, lock_person_rows(user_id))) do
        now = Arca.ServerMetaStorage.now!()

        with {:ok, generation, moved?} <- deny_row(user, now),
             {:ok, archived} <- archive_rows(active_ids(retire, athanors), now) do
          removed = delete_person_rows(user_id)
          withdrawn = delete_invitations(user.email)
          unfollowed = delete_follows(user_id, planned)
          hashes = delete_sessions(user_id)
          key_ids = revoke_keys(user_id, retire, now)

          with :ok <- deny_holds(user_id, retire) do
            %{
              empty_change()
              | transitioned: moved?,
                user: %{
                  Projection.user(user)
                  | status: "denied",
                    denied_at: if(moved?, do: now, else: user.denied_at),
                    security_generation: generation
                },
                user_generation: generation,
                athanor_generations: archived,
                athanors: moved(athanors, archived, "archived", now),
                archived_athanor_ids: Enum.sort(Map.keys(archived)),
                revoked_session_hashes: hashes,
                revoked_api_key_ids: key_ids,
                removed_membership_ids: Enum.map(removed, & &1.id),
                removed_memberships: removed,
                withdrawn_invitations: withdrawn,
                member_user_ids: members_by_estate(Map.keys(archived), peers),
                unfollowed: unfollowed
            }
          end
        end
      end

    committed(result)
  end

  # The estates a denial touches: the person's own and every one a row of
  # theirs names.
  defp estates_of(%User{personal_athanor_id: personal}, rows) do
    rows
    |> Enum.map(& &1.athanor_id)
    |> Enum.concat(List.wrap(personal))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp same_set(planned, locked), do: if(planned == locked, do: :ok, else: {:error, :set_changed})

  # A person may have no own estate; a pointer to one that has no row is
  # a broken relationship, and a denial does not skip it.
  defp personal_present(%User{personal_athanor_id: id}, athanors) when is_binary(id) do
    if Map.has_key?(athanors, id), do: :ok, else: {:error, :dangling_personal_athanor}
  end

  defp personal_present(%User{}, _athanors), do: :ok

  defp group_ids(athanors) do
    for {id, %Athanor{kind: "group"}} <- athanors, do: id
  end

  # What a denial archives, under the policy every leave follows: the
  # person's own estate; a frozen estate the moment anyone leaves it; an
  # open group the person leaves with no other active member.
  defp to_retire(%User{personal_athanor_id: personal}, athanors, rows, peers) do
    seated = for %Membership{athanor_id: id} <- rows, is_binary(id), uniq: true, do: id
    occupied = MapSet.new(peers, & &1.athanor_id)

    groups =
      for id <- seated,
          %Athanor{kind: "group"} = athanor <- List.wrap(athanors[id]),
          athanor.roster == "frozen" or not MapSet.member?(occupied, id),
          do: id

    personal
    |> List.wrap()
    |> Enum.filter(&Map.has_key?(athanors, &1))
    |> Enum.concat(groups)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp active_ids(ids, athanors),
    do: Enum.filter(ids, &match?(%Athanor{status: "active"}, athanors[&1]))

  defp deny_row(%User{status: "denied", security_generation: generation}, _now),
    do: {:ok, generation, false}

  defp deny_row(%User{} = user, now) do
    from(u in User,
      where:
        u.id == ^user.id and u.status == "active" and
          u.security_generation == ^user.security_generation,
      select: u.security_generation
    )
    |> Arca.Repo.update_all(
      set: [status: "denied", denied_at: now, updated_at: now],
      inc: [security_generation: 1]
    )
    |> case do
      {1, [generation]} -> {:ok, generation, true}
      _ -> {:error, :conflict}
    end
  end

  # arca:unscoped-ok a denial retires every membership of one person, across every estate.
  defp delete_person_rows(user_id) do
    {_count, rows} =
      Arca.Repo.delete_all(
        from(m in Membership,
          where: m.user_id == ^user_id,
          select: %{id: m.id, athanor_id: m.athanor_id, scope: m.scope}
        )
      )

    Enum.sort_by(rows || [], & &1.id)
  end

  defp delete_invitations(email) when is_binary(email) and email != "" do
    {_count, rows} =
      Arca.Repo.delete_all(
        from(m in Membership,
          where: m.email == ^email and m.status == "invited" and m.scope == "athanor",
          select: %{id: m.id, athanor_id: m.athanor_id}
        )
      )

    Enum.sort_by(rows || [], & &1.id)
  end

  defp delete_invitations(_email), do: []

  defp delete_follows(_user_id, []), do: 0

  # arca:unscoped-ok a denial drops one person's follows in every estate it touches.
  defp delete_follows(user_id, athanor_ids) do
    {count, _} =
      Arca.Repo.delete_all(
        from(s in ThreadSubscription,
          where: s.user_id == ^user_id and s.athanor_id in ^athanor_ids
        )
      )

    count
  end

  # arca:unscoped-ok a denial ends every session of one person, wherever it was established.
  defp delete_sessions(user_id) do
    {_count, hashes} =
      Arca.Repo.delete_all(from(s in Session, where: s.user_id == ^user_id, select: s.token_hash))

    hashes || []
  end

  # arca:unscoped-ok a denial revokes a person's keys in every estate, and every key of an estate it archives.
  defp revoke_keys(user_id, athanor_ids, now) do
    {_count, ids} =
      Arca.Repo.update_all(
        from(k in ApiKey,
          where:
            k.revoked == false and (k.created_by == ^user_id or k.athanor_id in ^athanor_ids),
          select: k.id
        ),
        set: [revoked: true, updated_at: now]
      )

    Enum.sort(ids || [])
  end

  # arca:unscoped-ok the postconditions of one person's denial, read across every estate.
  defp deny_holds(user_id, athanor_ids) do
    survivors = [
      from(u in User, where: u.id == ^user_id and u.status != "denied"),
      from(s in Session, where: s.user_id == ^user_id),
      from(m in Membership, where: m.user_id == ^user_id),
      from(k in ApiKey,
        where: k.revoked == false and (k.created_by == ^user_id or k.athanor_id in ^athanor_ids)
      ),
      from(a in Athanor, where: a.id in ^athanor_ids and a.status != "archived")
    ]

    if Enum.any?(survivors, &Arca.Repo.exists?/1),
      do: {:error, :postcondition_failed},
      else: :ok
  end

  defp members_by_estate(athanor_ids, peers) do
    for id <- athanor_ids, into: %{} do
      {id, for(%Membership{athanor_id: ^id, user_id: user} <- peers, do: user)}
    end
  end

  # ---- allow -----------------------------------------------------------------

  defp allow(user_id, verify) do
    result =
      with {:ok, user} <- lock_user(user_id),
           athanors = lock_athanors(List.wrap(user.personal_athanor_id)),
           :ok <- personal_present(user, athanors),
           athanor = athanors[user.personal_athanor_id],
           seats = lock_seats(user_id, athanor),
           :ok <-
             decide(verify, %{
               transition: :allow_user,
               user: Projection.user(user),
               athanor: Projection.athanor(athanor),
               memberships: Enum.map(seats, &Projection.membership/1)
             }) do
        now = Arca.ServerMetaStorage.now!()

        with {:ok, generation, moved?} <- allow_row(user, now),
             {:ok, reopened} <- reopen_rows(archived_ids(athanor), now),
             {:ok, seated} <- reseat(user_id, athanor, seats, now) do
          %{
            empty_change()
            | transitioned: moved?,
              user: %{
                Projection.user(user)
                | status: "active",
                  denied_at: nil,
                  security_generation: generation
              },
              user_generation: generation,
              athanor_generations: reopened,
              athanors: moved(athanors, reopened, "active", now),
              reopened_athanor_ids: Enum.sort(Map.keys(reopened)),
              seated_membership_ids: seated
          }
        end
      end

    committed(result)
  end

  defp allow_row(%User{status: "active", security_generation: generation}, _now),
    do: {:ok, generation, false}

  defp allow_row(%User{} = user, now) do
    from(u in User,
      where:
        u.id == ^user.id and u.status == "denied" and
          u.security_generation == ^user.security_generation,
      select: u.security_generation
    )
    |> Arca.Repo.update_all(
      set: [status: "active", denied_at: nil, updated_at: now],
      inc: [security_generation: 1]
    )
    |> case do
      {1, [generation]} -> {:ok, generation, true}
      _ -> {:error, :conflict}
    end
  end

  defp archived_ids(%Athanor{status: "archived", id: id}), do: [id]
  defp archived_ids(_athanor), do: []

  # The owner's seat in their own estate, which the denial removed with
  # every other row of theirs. A new row: the one the denial deleted is
  # never restored.
  defp reseat(_user_id, nil, _seats, _now), do: {:ok, []}

  defp reseat(user_id, %Athanor{id: athanor_id}, seats, now) do
    if Enum.any?(seats, &(&1.status == "active")) do
      {:ok, []}
    else
      %Membership{}
      |> Membership.changeset(%{
        id: Cyfr.UUID7.generate_id("mem"),
        user_id: user_id,
        scope: "athanor",
        status: "active",
        athanor_id: athanor_id,
        added_by: "system",
        created_at: now,
        updated_at: now
      })
      |> Arca.Repo.insert()
      |> case do
        {:ok, %Membership{id: id}} -> {:ok, [id]}
        {:error, _changeset} -> {:error, :conflict}
      end
    end
  end

  # ---- archive and reopen ----------------------------------------------------

  defp archive(athanor_id, verify) do
    result =
      with {:ok, athanor} <- lock_athanor(athanor_id),
           members = lock_members(athanor_id),
           :ok <-
             decide(verify, %{
               transition: :archive_athanor,
               athanor: Projection.athanor(athanor),
               member_user_ids: members
             }) do
        now = Arca.ServerMetaStorage.now!()

        with {:ok, archived} <-
               archive_rows(active_ids([athanor_id], %{athanor_id => athanor}), now) do
          key_ids = revoke_estate_keys(athanor_id, now)

          with :ok <- archive_holds(athanor_id) do
            %{
              empty_change()
              | transitioned: archived != %{},
                athanor_generations: archived,
                athanors: moved(%{athanor_id => athanor}, archived, "archived", now),
                archived_athanor_ids: Map.keys(archived),
                revoked_api_key_ids: key_ids,
                member_user_ids: %{athanor_id => members}
            }
          end
        end
      end

    committed(result)
  end

  defp unarchive(athanor_id, verify) do
    result =
      with {:ok, athanor} <- lock_athanor(athanor_id),
           :ok <-
             decide(verify, %{
               transition: :unarchive_athanor,
               athanor: Projection.athanor(athanor)
             }) do
        now = Arca.ServerMetaStorage.now!()

        with {:ok, reopened} <- reopen_rows(archived_ids(athanor), now) do
          %{
            empty_change()
            | transitioned: reopened != %{},
              athanor_generations: reopened,
              athanors: moved(%{athanor_id => athanor}, reopened, "active", now),
              reopened_athanor_ids: Map.keys(reopened)
          }
        end
      end

    committed(result)
  end

  defp archive_rows([], _now), do: {:ok, %{}}

  defp archive_rows(ids, now) do
    from(a in Athanor,
      where: a.id in ^ids and a.status == "active",
      select: {a.id, a.security_generation}
    )
    |> Arca.Repo.update_all(
      set: [status: "archived", archived_at: now, updated_at: now],
      inc: [security_generation: 1]
    )
    |> exactly(length(ids))
  end

  defp reopen_rows([], _now), do: {:ok, %{}}

  defp reopen_rows(ids, now) do
    from(a in Athanor,
      where: a.id in ^ids and a.status == "archived",
      select: {a.id, a.security_generation}
    )
    |> Arca.Repo.update_all(
      set: [status: "active", archived_at: nil, updated_at: now],
      inc: [security_generation: 1]
    )
    |> exactly(length(ids))
  end

  # Every locked row the statement named moved, or the transition is not
  # the one that was decided.
  defp exactly({count, rows}, count), do: {:ok, Map.new(rows)}
  defp exactly(_result, _count), do: {:error, :conflict}

  defp revoke_estate_keys(athanor_id, now) do
    {_count, ids} =
      Arca.Repo.update_all(
        from(k in ApiKey,
          where: k.athanor_id == ^athanor_id and k.revoked == false,
          select: k.id
        ),
        set: [revoked: true, updated_at: now]
      )

    Enum.sort(ids || [])
  end

  defp archive_holds(athanor_id) do
    survivors = [
      from(a in Athanor, where: a.id == ^athanor_id and a.status != "archived"),
      from(k in ApiKey, where: k.athanor_id == ^athanor_id and k.revoked == false)
    ]

    if Enum.any?(survivors, &Arca.Repo.exists?/1),
      do: {:error, :postcondition_failed},
      else: :ok
  end

  # ---- locks -----------------------------------------------------------------

  defp lock_user(user_id) do
    case from(u in User, where: u.id == ^user_id)
         |> QueryHelpers.for_update()
         |> Arca.Repo.one() do
      nil -> {:error, :not_found}
      %User{} = user -> {:ok, user}
    end
  end

  defp lock_athanor(athanor_id) do
    case lock_athanors([athanor_id]) do
      %{^athanor_id => athanor} -> {:ok, athanor}
      _ -> {:error, :not_found}
    end
  end

  defp lock_athanors([]), do: %{}

  defp lock_athanors(ids) do
    from(a in Athanor, where: a.id in ^ids, order_by: [asc: a.id])
    |> QueryHelpers.for_update()
    |> Arca.Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  # arca:unscoped-ok the plan of a denial reads one person's memberships across every estate.
  defp unlocked_rows(user_id),
    do: Arca.Repo.all(from(m in Membership, where: m.user_id == ^user_id))

  # arca:unscoped-ok a denial locks one person's memberships across every estate.
  defp lock_person_rows(user_id) do
    from(m in Membership, where: m.user_id == ^user_id, order_by: [asc: m.id])
    |> QueryHelpers.for_update()
    |> Arca.Repo.all()
  end

  # The other active members of the groups a denial touches: whether a
  # group is left empty is decided on them.
  defp lock_peers(_user_id, []), do: []

  # arca:unscoped-ok the rosters of the groups a denial touches, estates the caller named.
  defp lock_peers(user_id, athanor_ids) do
    from(m in Membership,
      where:
        m.athanor_id in ^athanor_ids and m.scope == "athanor" and m.status == "active" and
          m.user_id != ^user_id,
      order_by: [asc: m.id]
    )
    |> QueryHelpers.for_update()
    |> Arca.Repo.all()
  end

  # arca:unscoped-ok invitations are keyed by address, across every estate that holds one.
  defp lock_invitations(email) when is_binary(email) and email != "" do
    from(m in Membership,
      where: m.email == ^email and m.status == "invited" and m.scope == "athanor",
      order_by: [asc: m.id]
    )
    |> QueryHelpers.for_update()
    |> Arca.Repo.all()
  end

  defp lock_invitations(_email), do: []

  defp lock_seats(_user_id, nil), do: []

  defp lock_seats(user_id, %Athanor{id: athanor_id}) do
    from(m in Membership,
      where: m.user_id == ^user_id and m.athanor_id == ^athanor_id and m.scope == "athanor",
      order_by: [asc: m.id]
    )
    |> QueryHelpers.for_update()
    |> Arca.Repo.all()
  end

  defp lock_members(athanor_id) do
    from(m in Membership,
      where:
        m.athanor_id == ^athanor_id and m.scope == "athanor" and m.status == "active" and
          not is_nil(m.user_id),
      order_by: [asc: m.id]
    )
    |> QueryHelpers.for_update()
    |> Arca.Repo.all()
    |> Enum.map(& &1.user_id)
  end

  # ---- the answer ------------------------------------------------------------

  defp committed(%{} = change), do: change
  defp committed({:error, reason}), do: Arca.Repo.rollback(reason)

  # The estates a statement moved, as they stand after it.
  defp moved(athanors, generations, status, now) do
    for {id, generation} <- Enum.sort(generations) do
      %{
        Projection.athanor(athanors[id])
        | status: status,
          archived_at: if(status == "archived", do: now),
          security_generation: generation
      }
    end
  end

  defp empty_change do
    %{
      transitioned: false,
      user: nil,
      user_generation: nil,
      athanor_generations: %{},
      athanors: [],
      archived_athanor_ids: [],
      reopened_athanor_ids: [],
      revoked_session_hashes: [],
      revoked_api_key_ids: [],
      removed_membership_ids: [],
      removed_memberships: [],
      withdrawn_invitations: [],
      seated_membership_ids: [],
      member_user_ids: %{},
      unfollowed: 0
    }
  end
end
