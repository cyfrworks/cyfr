# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SecurityTransitions do
  @moduledoc """
  The standing transitions — deny and allow a person, which archive and
  reopen their athanor, and the declared restore —
  each as ONE transaction over every row it must change, or nothing.

  A transition changes a standing and retires what that standing issued:
  a denial marks the person denied, archives their own athanor, removes
  their memberships, removes their seats in shared threads
  and the invitations their identifier holds there, archives every pair
  they sit in and every shared thread they leave empty, deletes their sessions and revokes the
  keys they created and the keys of their athanor, the frame
  credentials (`Arca.FrameCredentials`), paired clients
  (`Arca.PairedClients`), device certificates (`Arca.DeviceCertificates`)
  and pending pairing invitations (`Arca.PairingInvitations`) of the
  person and of their athanor, and the person's passkeys
  (`Arca.Passkeys`); it withdraws every file offer they sent or that their
  athanor holds, and declines every other offer addressed to
  them (`Arca.FileOffers`), whose snapshots are released once it commits,
  and revokes every share of their athanor (`Arca.Shares`).
  Every transition that revokes a client
  or a credential voids the pending confirmations it confirmed
  (`Arca.PendingConfirmations`), and a denial voids the
  person's own open confirmations. Each
  commits together or not at all: a statement that fails rolls the whole
  transition back and the caller is answered the failure, so a denial can
  never report success with a credential of the person still standing. An allow restores the person's standing and
  their own athanor and seat and nothing else. It never un-revokes, re-creates or re-seats
  anything the retirement took, and it revokes again every frame
  credential, paired client, device certificate and pending pairing
  invitation the person still holds: a frame opened, a
  client paired or an invitation issued under the old standing never
  outlives a change of it.

  A declared restore (`restore/1`) consumes the marker `cyfr restore`
  writes (`mark_restore/1`): it raises every person's and athanor's
  standing, retires every session, suspends every key, webhook, paired
  client and passkey, revokes every open invitation to become a person
  here (`Arca.Invitations`), blocks every profile and stored credential,
  revokes every share, drops every standing allow, once binding and pending confirmation,
  settles every open run terminal, and opens one `restore_people` row for
  each person who held a passkey or device it suspended: a person who
  signs in only through a door has nothing to re-enable, and every
  confirmation of theirs already comes from one.
  This module owns those rows — written, read (`restore_open/2`,
  `restore_checklist/2`) and closed
  (`close_restore!/1`) — and the kit's challenges and credential the
  recovering person proves their kit with.

  Every real change of a standing raises the row's `security_generation`
  in the same statement. A credential is issued only against the
  generation its context read (`Arca.SecurityTransitions.Issuance`), so a
  context read before a retirement cannot issue after the restore.

  ## Lock order

  Every transition, and every credential issuance, takes its row locks in
  one order: people sorted by id, athanors sorted by id, then
  memberships, then shared threads sorted by id
  (`Arca.SharedThreads`) and their people, then cached identity heads, then
  sessions, then API keys, then frame credentials, then paired clients,
  then device certificates, pairing invitations, admission invitations
  (`Arca.Invitations`), passkeys and pending confirmations, then file
  offers by offer and file name (`Arca.FileOffers`), then shares by id
  and the profiles that depend on them, by athanor and id (`Arca.Shares`,
  `Arca.ConsentStorage`).
  A writer of a membership row naming a person takes the person's lock
  first (`Arca.Members`), so a seat racing a denial
  waits for it, or it for them; a file offer is written under its two
  people's locks and its athanor's, shared, so it waits for a denial
  holding them, and either sees an offer that landed first.
  An allow, which counts the server's active athanors for its caller,
  takes the server-wide census lock (`Arca.AthanorCensus`)
  after its row locks and right before the caller's policy, as a mint
  takes it after the people it holds. After it it writes only the rows
  it holds and the credentials, clients and invitations that hang off
  them, which no holder of the census lock locks before taking it. A
  transition taking only a suffix of that order never goes back for an
  earlier lock. A declared restore takes its marker's row first, which
  nothing else locks, then every person and every athanor in id order. A
  re-enable takes its item's row, then the person's `restore_people` row,
  then the kit's `server_meta` row. On PostgreSQL the order is the deadlock rule; on SQLite
  the write lock every transaction takes at entry is the lock and the
  order is code order (`Arca.Repo.locking_transaction/2`).

  A denial computes the athanors it touches from the person's memberships,
  locks them, then locks the memberships and computes the set again, and
  once more after the caller's policy, right before it writes. A set that
  moved in between (a seat taken while the athanors were being locked, or
  while the policy was asked) rolls the attempt back, because the athanor
  locks cannot be taken after the membership locks; the transition runs
  again, three times at most, and then answers `{:error, :conflict}`. It
  never continues on a partial view. A seat into an athanor the denial
  holds waits for it (`Arca.Members.seat/2` locks the athanor first).

  ## The deadline

  A transition's transaction holds its connection for at most a minute,
  where the repository's default for one checkout is 15 s. It is one
  transaction over every row the standing issued, and nothing caps how
  many file offers one person or athanor holds open, so its deadline is
  sized for an atomic retirement over every one of them; the default is
  a budget for an ordinary request. The minute bounds the whole
  transaction, the statements inside it included, which have no deadline
  of their own. Past it the connection is closed, the transaction rolls
  back and the transition answers `:database_error`. A writer waiting
  behind it, on a row lock it holds on PostgreSQL or on SQLite's one
  write lock, fails on its own deadline, as it does behind any other
  transaction. A denial run again after a moved set has a minute of its
  own.

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
  caller announces from: the session hashes each DELETE returned, the
  key, frame credential, paired client, device certificate, pairing
  invitation and passkey ids each UPDATE returned, the confirmations it
  voided, the athanors archived or reopened with their new generations,
  the memberships removed and seats restored, the
  members of each archived athanor, the person's generation, and the shares
  it revoked (`revoked_share_ids`). Refusals:
  `:not_found`, `:dangling_personal_athanor` (a person's own-athanor pointer
  names no row), `:conflict`, `:postcondition_failed`, `:cross_tenant`,
  `:no_athanor`, `:database_error`, or the callback's own reason.
  """

  import Ecto.Query

  alias Arca.QueryHelpers

  alias Arca.{
    AthanorCensus,
    DeviceCertificates,
    FrameCredentials,
    Invitations,
    PairedClients,
    PairingInvitations,
    Passkeys,
    PendingConfirmations
  }

  alias Arca.Schemas.{
    ApiKey,
    Approval,
    Athanor,
    ConsentVaultRef,
    DeviceCertificate,
    Execution,
    ExecutionAttempt,
    FileOffer,
    FrameCredential,
    Invitation,
    Membership,
    PairedClient,
    PairingInvitation,
    Passkey,
    PendingConfirmation,
    PersonIdentity,
    Profile,
    RestorePerson,
    ServerMeta,
    Session,
    Share,
    SharedThread,
    SharedThreadMember,
    StorageWriteIntent,
    ToolGrant,
    Turn,
    TurnStep,
    User,
    VaultEntry,
    Webhook
  }

  alias Arca.SecurityTransitions.Projection
  alias Arca.StatusTransitions

  @attempts 3
  # How long one transaction of a transition may hold its connection
  # (the moduledoc's "The deadline").
  @deadline_ms 60_000
  @open_confirmation ~w(pending confirmed)
  # The declared restore's marker (`mark_restore/1`, `restore/1`).
  @restore_marker "restore_pending"
  # The kit's challenges, one `server_meta` row each, keyed by digest.
  @challenge_prefix "restore_kit_challenge:"
  # The kit credentials, one `server_meta` row each, keyed by digest.
  @credential_prefix "restore_kit:"

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
          required(:revoked_frame_credential_ids) => [String.t()],
          required(:revoked_paired_client_ids) => [String.t()],
          required(:revoked_device_certificate_ids) => [String.t()],
          required(:revoked_pairing_invitation_ids) => [String.t()],
          required(:revoked_passkey_ids) => [String.t()],
          required(:voided_confirmation_ids) => [String.t()],
          required(:removed_membership_ids) => [String.t()],
          required(:removed_memberships) => [map()],
          required(:seated_membership_ids) => [String.t()],
          required(:member_user_ids) => %{String.t() => [String.t()]},
          required(:ended_offer_ids) => [String.t()],
          required(:revoked_share_ids) => [String.t()],
          required(:left_shared_thread_ids) => [String.t()],
          required(:archived_shared_thread_ids) => [String.t()]
        }

  @doc """
  Deny the person `user_id` on this server, with everything a denial
  retires (see the module doc). A person already denied is denied again:
  nothing moves their generation, and the retirement is re-run and its
  postconditions checked, so a retry finishes what a failure left.
  """
  @spec deny_user(Prima.Actor.t(), String.t(), keyword()) :: {:ok, change()} | {:error, term()}
  def deny_user(%Prima.Actor{scope: :platform, system: true}, user_id, opts)
      when is_binary(user_id) and user_id != "" and is_list(opts) do
    verify = Keyword.fetch!(opts, :verify)

    case run("Arca.SecurityTransitions.deny_user", fn -> deny(user_id, verify) end) do
      {:ok, change} ->
        # The offers the denial ended release their snapshots and announce
        # themselves only once it committed.
        {ended, change} = Map.pop(change, :ended_offers, [])
        Arca.FileOffers.after_end(ended)
        {:ok, change}

      refusal ->
        refusal
    end
  end

  def deny_user(%Prima.Actor{}, _user_id, _opts), do: {:error, :cross_tenant}

  @doc """
  Restore the person `user_id`: their standing, their own athanor when it
  is archived, and their seat in it. Sessions, keys, shared-thread seats
  and invitations the denial took stay taken.
  """
  @spec allow_user(Prima.Actor.t(), String.t(), keyword()) :: {:ok, change()} | {:error, term()}
  def allow_user(%Prima.Actor{scope: :platform, system: true}, user_id, opts)
      when is_binary(user_id) and user_id != "" and is_list(opts) do
    verify = Keyword.fetch!(opts, :verify)
    run("Arca.SecurityTransitions.allow_user", fn -> allow(user_id, verify) end)
  end

  def allow_user(%Prima.Actor{}, _user_id, _opts), do: {:error, :cross_tenant}

  # ---- the runner ------------------------------------------------------------

  # A raised database error rolls the transaction back and answers
  # `:database_error`; a set that moved between planning and locking runs
  # the whole transaction again, `@attempts` times at most, each within
  # `@deadline_ms`.
  defp run(tag, body) do
    tag
    |> Arca.Repo.Errors.with_db_rescue(fn -> attempt(body, @attempts) end)
    |> Arca.Data.project()
  end

  defp attempt(_body, 0), do: {:error, :conflict}

  defp attempt(body, left) do
    case Arca.Repo.locking_transaction(body, timeout: @deadline_ms) do
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
           planned = athanors_of(user, unlocked_rows(user_id)),
           athanors = lock_athanors(planned),
           :ok <- personal_present(user, athanors),
           rows = lock_person_rows(user_id),
           :ok <- same_set(planned, athanors_of(user, rows)),
           identifier = identifier_of(user_id),
           threads = lock_shared_threads(user_id),
           retire = to_retire(user, athanors),
           :ok <-
             decide(verify, %{
               transition: :deny_user,
               user: Projection.user(user),
               athanors: athanors |> Map.values() |> Enum.map(&Projection.athanor/1),
               memberships: Enum.map(rows, &Projection.membership/1),
               archive: retire
             }),
           # Asked again after the policy, right before the first write, so
           # the set the policy was shown is the set the statements act on.
           :ok <- same_set(planned, athanors_of(user, lock_person_rows(user_id))) do
        now = Arca.ServerMetaStorage.now!()

        with {:ok, generation, moved?} <- deny_row(user, now),
             {:ok, archived} <- archive_rows(active_ids(retire, athanors), now) do
          removed = delete_person_rows(user_id)
          hashes = delete_sessions(user_id)
          key_ids = revoke_keys(user_id, retire, now)
          frame_ids = revoke_frames(user_id, retire)
          paired_ids = revoke_paired(user_id, retire)
          cert_ids = revoke_certificates(user_id, retire)
          invitation_ids = revoke_pairing_invitations(user_id, retire)
          passkey_ids = Passkeys.revoke_all(from(p in Passkey, where: p.user_id == ^user_id))
          # The confirmations are voided only after the passkeys are revoked:
          # a confirm locks its client, then its passkey, then its record, and
          # the denial takes them in that order too, so neither waits on the
          # other across a lock the other holds.
          dependents = PairedClients.retire_dependents!(paired_ids)
          by_passkeys = PendingConfirmations.void_confirmed_by!(:passkey, passkey_ids)
          own = void_confirmations(from(c in PendingConfirmation, where: c.user_id == ^user_id))
          ended_offers = Arca.FileOffers.end_for_person!(user_id, retire)
          {left, ended} = leave_shared_threads(user_id, identifier, threads, now)

          with {:ok, share_ids} <- revoke_shares(retire),
               :ok <- deny_holds(user_id, retire) do
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
                revoked_frame_credential_ids: frame_ids,
                revoked_paired_client_ids: paired_ids,
                revoked_device_certificate_ids: merged_ids(dependents.certificate_ids, cert_ids),
                revoked_pairing_invitation_ids: invitation_ids,
                revoked_passkey_ids: passkey_ids,
                voided_confirmation_ids:
                  merged_ids(dependents.confirmation_ids, merged_ids(by_passkeys, own)),
                removed_membership_ids: Enum.map(removed, & &1.id),
                removed_memberships: removed,
                member_user_ids: Map.new(Map.keys(archived), &{&1, [user_id]}),
                ended_offer_ids:
                  ended_offers |> Enum.map(& &1.offer_id) |> Enum.uniq() |> Enum.sort(),
                revoked_share_ids: share_ids,
                left_shared_thread_ids: left,
                archived_shared_thread_ids: ended
            }
            |> Map.put(:ended_offers, ended_offers)
          end
        end
      end

    committed_change(result)
  end

  # The shared threads the person sits in, locked in id order after the
  # athanors and their memberships, as the standing order takes them. A
  # new seat of theirs waits for the person's lock the denial took first.
  # arca:unscoped-ok a shared thread is no athanor's; a person's are locked by their seats.
  defp lock_shared_threads(user_id) do
    from(t in SharedThread,
      where:
        t.id in subquery(
          from(m in SharedThreadMember,
            where: m.user_id == ^user_id and m.status == "active",
            select: m.thread_id
          )
        ),
      order_by: [asc: t.id]
    )
    |> QueryHelpers.for_update()
    |> Arca.Repo.all()
  end

  # The person's seats in the shared threads `threads` holds, and the
  # invitations their identifier holds in any, removed; then every active
  # pair among them and every thread with no one left seated archived,
  # one more `security_generation` each. Answers the threads they left and
  # the ones it archived, each sorted.
  # arca:unscoped-ok a shared thread is no athanor's; a person's seats there are theirs.
  defp leave_shared_threads(user_id, identifier, threads, now) do
    Arca.Repo.delete_all(
      from(m in SharedThreadMember, where: m.user_id == ^user_id and m.status == "active")
    )

    if is_binary(identifier) and identifier != "" do
      Arca.Repo.delete_all(
        from(m in SharedThreadMember,
          where: m.person_identifier == ^identifier and m.status == "invited"
        )
      )
    end

    ids = Enum.map(threads, & &1.id)

    occupied =
      from(m in SharedThreadMember,
        where: m.thread_id in ^ids and m.status == "active",
        distinct: true,
        select: m.thread_id
      )
      |> Arca.Repo.all()
      |> MapSet.new()

    ending =
      for %SharedThread{status: "active"} = thread <- threads,
          thread.kind == "pair" or not MapSet.member?(occupied, thread.id),
          do: thread.id

    {_count, ended} =
      Arca.Repo.update_all(
        from(t in SharedThread,
          where: t.id in ^ending and t.status == "active",
          select: t.id
        ),
        set: [status: "archived", archived_at: now],
        inc: [security_generation: 1]
      )

    {Enum.sort(ids), Enum.sort(ended || [])}
  end

  # Every share of the athanors `athanor_ids` revoked and their dependents
  # blocked, last in the transition, after every row the standing order
  # takes before the shares.
  defp revoke_shares(athanor_ids) do
    Enum.reduce_while(athanor_ids, {:ok, []}, fn athanor_id, {:ok, acc} ->
      case Arca.Shares.revoke_by_athanor(
             Prima.Actor.in_athanor(athanor_id),
             StatusTransitions.blocked_profile_status()
           ) do
        {:ok, %{share_ids: ids}} -> {:cont, {:ok, acc ++ ids}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.sort(ids)}
      error -> error
    end
  end

  # The athanors a denial touches: the person's own and every one a row of
  # theirs names.
  defp athanors_of(%User{personal_athanor_id: personal}, rows) do
    rows
    |> Enum.map(& &1.athanor_id)
    |> Enum.concat(List.wrap(personal))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp same_set(planned, locked), do: if(planned == locked, do: :ok, else: {:error, :set_changed})

  # A person may have no own athanor; a pointer to one that has no row is
  # a broken relationship, and a denial does not skip it.
  defp personal_present(%User{personal_athanor_id: id}, athanors) when is_binary(id) do
    if Map.has_key?(athanors, id), do: :ok, else: {:error, :dangling_personal_athanor}
  end

  defp personal_present(%User{}, _athanors), do: :ok

  # What a denial archives: the person's own athanor.
  defp to_retire(%User{personal_athanor_id: personal}, athanors) do
    personal |> List.wrap() |> Enum.filter(&Map.has_key?(athanors, &1))
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

  # arca:unscoped-ok a denial retires every membership of one person, across every athanor.
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

  defp identifier_of(user_id) do
    Arca.Repo.one(from(p in PersonIdentity, where: p.user_id == ^user_id, select: p.identifier))
  end

  # arca:unscoped-ok a denial ends every session of one person, wherever it was established.
  defp delete_sessions(user_id) do
    {_count, hashes} =
      Arca.Repo.delete_all(from(s in Session, where: s.user_id == ^user_id, select: s.token_hash))

    hashes || []
  end

  # arca:unscoped-ok a denial revokes a person's keys in every athanor, and every key of an athanor it archives.
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

  # A transition revokes a person's frames in every athanor, and every
  # frame of an athanor it archives (`Arca.FrameCredentials.revoke_all/1`).
  defp revoke_frames(user_id, athanor_ids) do
    FrameCredentials.revoke_all(
      from(f in FrameCredential, where: f.user_id == ^user_id or f.athanor_id in ^athanor_ids)
    )
  end

  # A transition revokes a person's paired clients in every athanor, and
  # every client of an athanor it archives (`Arca.PairedClients.revoke_all/1`).
  defp revoke_paired(user_id, athanor_ids) do
    PairedClients.revoke_all(
      from(p in PairedClient, where: p.user_id == ^user_id or p.athanor_id in ^athanor_ids)
    )
  end

  # Wherever a transition revokes paired clients it revokes certificates:
  # a person's in every athanor, and every certificate of an athanor it
  # archives (`Arca.DeviceCertificates.revoke_all/1`).
  defp revoke_certificates(user_id, athanor_ids) do
    DeviceCertificates.revoke_all(
      from(c in DeviceCertificate, where: c.user_id == ^user_id or c.athanor_id in ^athanor_ids)
    )
  end

  # A person's pending pairing invitations in every athanor, and every
  # pending invitation of an athanor it archives
  # (`Arca.PairingInvitations.revoke_all/1`).
  defp revoke_pairing_invitations(user_id, athanor_ids) do
    PairingInvitations.revoke_all(
      from(i in PairingInvitation, where: i.user_id == ^user_id or i.athanor_id in ^athanor_ids)
    )
  end

  defp void_confirmations(query), do: PendingConfirmations.void_all(query)

  # arca:unscoped-ok the postconditions of one person's denial, read across every athanor.
  defp deny_holds(user_id, athanor_ids) do
    survivors = [
      from(u in User, where: u.id == ^user_id and u.status != "denied"),
      from(s in Session, where: s.user_id == ^user_id),
      from(m in Membership, where: m.user_id == ^user_id),
      from(m in SharedThreadMember, where: m.user_id == ^user_id),
      from(k in ApiKey,
        where: k.revoked == false and (k.created_by == ^user_id or k.athanor_id in ^athanor_ids)
      ),
      from(f in FrameCredential,
        where: f.state != "revoked" and (f.user_id == ^user_id or f.athanor_id in ^athanor_ids)
      ),
      from(p in PairedClient,
        where: p.standing != "revoked" and (p.user_id == ^user_id or p.athanor_id in ^athanor_ids)
      ),
      from(c in DeviceCertificate,
        where: c.state != "revoked" and (c.user_id == ^user_id or c.athanor_id in ^athanor_ids)
      ),
      from(i in PairingInvitation,
        where: i.state == "pending" and (i.user_id == ^user_id or i.athanor_id in ^athanor_ids)
      ),
      from(p in Passkey, where: p.user_id == ^user_id and p.state != "revoked"),
      from(c in PendingConfirmation,
        where: c.user_id == ^user_id and c.state in ^@open_confirmation
      ),
      from(a in Athanor, where: a.id in ^athanor_ids and a.status != "archived"),
      from(s in Share, where: s.athanor_id in ^athanor_ids and s.status == "active"),
      from(o in FileOffer,
        where:
          o.status == "offered" and
            (o.sender_user_id == ^user_id or o.recipient_user_id == ^user_id or
               o.athanor_id in ^athanor_ids)
      )
    ]

    if Enum.any?(survivors, &Arca.Repo.exists?/1),
      do: {:error, :postcondition_failed},
      else: :ok
  end

  # ---- allow -----------------------------------------------------------------

  defp allow(user_id, verify) do
    result =
      with {:ok, user} <- lock_user(user_id),
           athanors = lock_athanors(List.wrap(user.personal_athanor_id)),
           :ok <- personal_present(user, athanors),
           athanor = athanors[user.personal_athanor_id],
           seats = lock_seats(user_id, athanor),
           :ok <- AthanorCensus.lock(),
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
          frame_ids = revoke_frames(user_id, [])
          paired_ids = revoke_paired(user_id, [])
          dependents = PairedClients.retire_dependents!(paired_ids)
          cert_ids = revoke_certificates(user_id, [])
          invitation_ids = revoke_pairing_invitations(user_id, [])

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
              revoked_frame_credential_ids: frame_ids,
              revoked_paired_client_ids: paired_ids,
              revoked_device_certificate_ids: merged_ids(dependents.certificate_ids, cert_ids),
              revoked_pairing_invitation_ids: invitation_ids,
              voided_confirmation_ids: dependents.confirmation_ids,
              seated_membership_ids: seated
          }
        end
      end

    committed_change(result)
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

  # The owner's seat in their own athanor, which the denial removed with
  # every other row of theirs. A new row: the one the denial deleted is
  # never restored.
  defp reseat(_user_id, nil, _seats, _now), do: {:ok, []}

  defp reseat(user_id, %Athanor{id: athanor_id}, seats, now) do
    if Enum.any?(seats, &(&1.status == "active")) do
      {:ok, []}
    else
      %Membership{}
      |> Membership.changeset(%{
        id: Prima.UUID7.generate_id("mem"),
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

  # ---- the athanor's standing -------------------------------------------------

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

  # ---- the declared restore ------------------------------------------------------

  @doc """
  Write the declared restore's marker (`server_meta` `restore_pending`,
  its value a new restore id), or answer the one already written, so
  running it twice marks one restore. `cyfr restore` runs it through
  `Cyfr.Release.mark_restore/0` once the backup's parts are back and
  before the cell starts; the boot consumes it (`restore/1`).
  """
  @spec mark_restore(Prima.Actor.t()) :: {:ok, String.t()} | {:error, term()}
  def mark_restore(%Prima.Actor{scope: :platform, system: true}) do
    restore_id = Prima.UUID7.generate_id("rst")

    case Arca.ServerMetaStorage.put_new(@restore_marker, restore_id) do
      {:ok, :recorded} -> {:ok, restore_id}
      {:error, :exists} -> Arca.ServerMetaStorage.get(@restore_marker)
      {:error, _unanswered} = refusal -> refusal
    end
  end

  def mark_restore(%Prima.Actor{}), do: {:error, :cross_tenant}

  @doc """
  Consume the declared restore's marker, when there is one, in one
  transaction under this member's slot (`opts[:slot]`, checked on the
  database's clock first and again before commit), or answer
  `{:ok, :none}` with nothing written.

  The transition (`ARCHITECTURE.md` §6.9) raises every person's and every
  athanor's `security_generation`, so nothing admitted under the backup's
  standing stands after it: an execution grant read before it never
  admits a successor (`Arca.ExecutionStanding`), a context read before
  it issues nothing, and an invitation issued before it admits no one
  (`Arca.Invitations`). It deletes every session; suspends every
  unrevoked API key, every webhook, every active paired client and every
  active passkey; revokes every frame credential, every pending pairing
  invitation and every open admission invitation
  (`Arca.Invitations.revoke_all!/0`); deletes every pending confirmation
  (`Arca.PendingConfirmations.delete_all!/0`); moves every active profile
  to `needs_consent`, every active vault entry to `needs_reauth` and
  every active share to `revoked` (`Arca.StatusTransitions.restored/1`),
  answering the shares in `revoked_share_ids`; deletes every standing
  allow (`tool_grants` rows of effect `allow`; denies stay);
  drops every unconsumed once binding by consuming it under the restore
  (`consumed_by_root` `restore:<restore id>`); expires every pending
  approval; and settles every open run terminal under
  `Prima.ExecutionState` and `Prima.TurnState`: an execution `failed`,
  its attempt `lapsed` with outcome `uncertain` and the attempt's pending
  write intents `uncertain`, a turn `uncertain` with its open steps. Rows
  already suspended, blocked, revoked or tombstoned keep their state. It
  then closes every recovery an earlier restore left open, as superseded,
  with every kit credential and challenge it left, writes one open
  `restore_people` row for each person who holds a method it suspended,
  or one an earlier restore suspended and they have not re-enabled — a
  passkey or a paired client — and deletes the marker it read, so a retry after commit finds no marker and moves
  nothing, and a crash before commit leaves the marker for the next boot.

  The membership freeze is what those rows mean: a shared thread with a
  member whose row is open admits no new member (`frozen_shared_threads/0`).

  Every statement's postcondition is read before commit; a survivor rolls
  the whole transition back as `:postcondition_failed`. A lost slot is
  `:slot_lost`; a store that cannot answer, `:database_error`.
  """
  @spec restore(keyword()) :: {:ok, map() | :none} | {:error, term()}
  def restore(opts) when is_list(opts) do
    slot = Keyword.fetch!(opts, :slot)

    Arca.Repo.Errors.with_db_rescue("Arca.SecurityTransitions.restore", fn ->
      Arca.Repo.locking_transaction(fn -> declared_restore(slot) end, timeout: @deadline_ms)
    end)
    |> Arca.Data.project()
  end

  @doc """
  The restore id of the person's open `restore_people` row, or nil when
  they have none: while it is open their confirmation comes from a door
  this home re-authenticates or from their recovery kit.
  """
  @spec restore_open(Prima.Actor.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, :cross_tenant | :database_error}
  def restore_open(%Prima.Actor{scope: :platform, system: true}, user_id)
      when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.SecurityTransitions.restore_open", fn ->
      {:ok, Arca.Repo.one(open_rows(user_id))}
    end)
    |> Arca.Data.project()
  end

  def restore_open(%Prima.Actor{}, _user_id), do: {:error, :cross_tenant}

  @doc false
  @spec restore_open!(String.t()) :: String.t() | nil
  # `restore_open/2` inside the caller's locking transaction, the person's
  # open row locked, so a close that commits first is seen and one that
  # starts later waits.
  # arca:db-raise-ok a transaction step: its callers rescue around the transaction.
  def restore_open!(user_id) when is_binary(user_id) do
    user_id |> open_rows() |> QueryHelpers.for_update() |> Arca.Repo.one()
  end

  @doc false
  @spec close_restore!(String.t()) :: [String.t()]
  # Close the person's open rows in the caller's locking transaction: the
  # write that re-enabled one of their methods, or a platform
  # administrator's activation of one for them. Their kit credential goes
  # with it. Another person's row is never touched.
  # arca:db-raise-ok a transaction step: its callers rescue around the transaction.
  def close_restore!(user_id) when is_binary(user_id) do
    now = Arca.ServerMetaStorage.now!()

    {_count, ids} =
      Arca.Repo.update_all(
        from(r in RestorePerson,
          where: r.user_id == ^user_id and r.open == true,
          select: r.restore_id
        ),
        set: [open: false, closed_at: now]
      )

    drop_credentials!(user_id)
    Enum.sort(ids || [])
  end

  @doc """
  A platform administrator's close of the person `user_id`'s recovery from
  a declared restore (`person.close_recovery`), in one locking
  transaction: `opts[:verify]` is asked first over `%{user_id: user_id}`
  (the administrator's confirmation is consumed there, under their own
  locks), then the person's open row is locked and every open row of
  theirs closed, with their kit credential. Another person's row is never
  touched. `{:error, :not_recovering}` when the person has none open.
  """
  @spec close_restore(Prima.Actor.t(), String.t(), keyword()) ::
          {:ok, %{closed_restore_ids: [String.t()]}} | {:error, term()}
  def close_restore(%Prima.Actor{scope: :platform, system: true}, user_id, opts)
      when is_binary(user_id) and is_list(opts) do
    verify = Keyword.fetch!(opts, :verify)

    Arca.Repo.Errors.with_db_rescue("Arca.SecurityTransitions.close_restore", fn ->
      Arca.Repo.locking_transaction(fn ->
        with :ok <- verify.(%{user_id: user_id}),
             restore_id when is_binary(restore_id) <- restore_open!(user_id) do
          %{closed_restore_ids: close_restore!(user_id)}
        else
          nil -> Arca.Repo.rollback(:not_recovering)
          {:error, reason} -> Arca.Repo.rollback(reason)
        end
      end)
    end)
    |> Arca.Data.project()
  end

  def close_restore(%Prima.Actor{}, _user_id, _opts), do: {:error, :cross_tenant}

  @doc false
  @spec frozen_shared_threads() :: Ecto.Query.t()
  # The ids of every shared thread a declared restore holds: one of its
  # people still has an open `restore_people` row. A query the caller runs
  # in its own transaction under the thread's lock, as a seat, an
  # invitation and an activation do (`Arca.SharedThreadMembers`), so no one
  # new is seated in such a thread by any path until each has recovered.
  def frozen_shared_threads do
    from(m in SharedThreadMember,
      join: r in RestorePerson,
      on: r.user_id == m.user_id and r.open == true,
      where: m.status == "active",
      select: m.thread_id
    )
  end

  @doc """
  The person's restore checklist: the open restore, whether any declared
  restore ever found them (`restored`), and every API key and webhook
  they created, paired client and passkey of theirs held suspended; and
  every profile needing consent and every vault entry needing
  re-authentication in the athanors they sit in. Each item is a plain map
  of the fields the checklist shows, never a hash, a secret or sealed
  bytes.
  """
  @spec restore_checklist(Prima.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :cross_tenant | :database_error}
  def restore_checklist(%Prima.Actor{scope: :platform, system: true}, user_id)
      when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.SecurityTransitions.restore_checklist", fn ->
      {:ok, checklist(user_id)}
    end)
    |> Arca.Data.project()
  end

  def restore_checklist(%Prima.Actor{}, _user_id), do: {:error, :cross_tenant}

  @doc """
  Hold a kit challenge for the person's open restore `restore_id`: a row
  of its own, keyed by the challenge's digest, until it is redeemed or
  expires, so a challenge anyone asks for never displaces another one the
  person is answering, nor their kit credential. Expired challenges are
  removed as a new one is held. `{:error, :closed}` when the person has
  no open row under that restore; `{:error, :not_owner}` on a member whose
  slot was taken over.
  """
  @spec put_kit_challenge(Prima.Actor.t(), String.t(), String.t(), String.t(), DateTime.t()) ::
          :ok | {:error, :closed | :not_owner | :cross_tenant | :database_error}
  def put_kit_challenge(
        %Prima.Actor{scope: :platform, system: true},
        user_id,
        restore_id,
        digest,
        %DateTime{} = expires_at
      )
      when is_binary(user_id) and is_binary(restore_id) and is_binary(digest) do
    kit_write("Arca.SecurityTransitions.put_kit_challenge", user_id, restore_id, fn ->
      drop_expired_challenges()

      put_meta(
        challenge_key(digest),
        %{"u" => user_id, "r" => restore_id, "e" => DateTime.to_unix(expires_at, :millisecond)}
      )
    end)
  end

  def put_kit_challenge(%Prima.Actor{}, _user_id, _restore_id, _digest, _expires_at),
    do: {:error, :cross_tenant}

  @doc """
  Redeem the kit challenge whose digest is `challenge_digest`, held for
  this person's open restore `restore_id`, once and before its expiry on
  the database's clock, for the person's kit credential: its digest and
  expiry replace any credential they held. One transaction, with the
  person's open row locked first and the challenge deleted as it is
  redeemed. `{:error, :challenge_refused}` for no such challenge, another
  person's or restore's, an expired one or one already redeemed;
  `{:error, :closed}` when the row has closed.
  """
  @spec redeem_kit_challenge(
          Prima.Actor.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          DateTime.t()
        ) ::
          :ok
          | {:error, :challenge_refused | :closed | :not_owner | :cross_tenant | :database_error}
  def redeem_kit_challenge(
        %Prima.Actor{scope: :platform, system: true},
        user_id,
        restore_id,
        challenge_digest,
        credential_digest,
        %DateTime{} = expires_at
      )
      when is_binary(user_id) and is_binary(restore_id) and is_binary(challenge_digest) and
             is_binary(credential_digest) do
    kit_write("Arca.SecurityTransitions.redeem_kit_challenge", user_id, restore_id, fn ->
      with :ok <- take_challenge(challenge_digest, user_id, restore_id) do
        drop_credentials!(user_id)

        put_meta(credential_key(credential_digest), %{
          "u" => user_id,
          "r" => restore_id,
          "e" => DateTime.to_unix(expires_at, :millisecond)
        })
      end
    end)
  end

  def redeem_kit_challenge(%Prima.Actor{}, _user, _restore, _challenge, _credential, _expires),
    do: {:error, :cross_tenant}

  @doc """
  The person's kit credential whose digest is `credential_digest`, while
  it is unexpired on the database's clock, the person's row under its
  restore is open and the person is in good standing (not denied):
  `{:ok, restore_id}`, else `{:error, :not_standing}`.
  """
  @spec kit_credential(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :not_standing | :cross_tenant | :database_error}
  def kit_credential(%Prima.Actor{scope: :platform, system: true}, user_id, credential_digest)
      when is_binary(user_id) and is_binary(credential_digest) do
    Arca.Repo.Errors.with_db_rescue("Arca.SecurityTransitions.kit_credential", fn ->
      kit_stands!(user_id, credential_digest)
    end)
    |> Arca.Data.project()
  end

  def kit_credential(%Prima.Actor{}, _user_id, _digest), do: {:error, :cross_tenant}

  @doc """
  Whose kit credential the digest `credential_digest` names: `{:ok,
  user_id}` while it is held, else `{:error, :not_standing}`. The
  credential carries no person, so a bearer is found by its digest alone;
  whether it still stands is `kit_credential/3`'s.
  """
  @spec kit_holder(Prima.Actor.t(), String.t()) ::
          {:ok, String.t()} | {:error, :not_standing | :cross_tenant | :database_error}
  def kit_holder(%Prima.Actor{scope: :platform, system: true}, credential_digest)
      when is_binary(credential_digest) do
    Arca.Repo.Errors.with_db_rescue("Arca.SecurityTransitions.kit_holder", fn ->
      with %ServerMeta{value: value} <-
             Arca.Repo.get(ServerMeta, credential_key(credential_digest)),
           {:ok, %{"u" => user_id}} when is_binary(user_id) <- Jason.decode(value) do
        {:ok, user_id}
      else
        _none -> {:error, :not_standing}
      end
    end)
    |> Arca.Data.project()
  end

  def kit_holder(%Prima.Actor{}, _digest), do: {:error, :cross_tenant}

  @doc false
  @spec kit_stands!(String.t(), String.t()) :: {:ok, String.t()} | {:error, :not_standing}
  # `kit_credential/3` inside the caller's transaction: the write a kit
  # credential authorizes reads it standing there, after the person's open
  # row (`restore_open!/1`) is locked.
  # arca:db-raise-ok a transaction step: its callers rescue around the transaction.
  def kit_stands!(user_id, credential_digest) do
    now = Arca.ServerMetaStorage.now!()

    with %ServerMeta{value: value} <-
           Arca.Repo.get(ServerMeta, credential_key(credential_digest)),
         {:ok, %{"u" => holder, "r" => restore_id, "e" => expires}} <- Jason.decode(value),
         true <- holder == user_id,
         true <- is_integer(expires) and DateTime.to_unix(now, :millisecond) < expires,
         true <- Arca.Repo.exists?(open_row(user_id, restore_id)),
         true <- standing?(user_id) do
      {:ok, restore_id}
    else
      _no -> {:error, :not_standing}
    end
  end

  # The person in good standing, read under a shared lock on their row: a
  # denial that committed first is seen, and one that starts later waits
  # for the write this check admits.
  defp standing?(user_id) do
    from(u in User, where: u.id == ^user_id and u.status == "active", select: u.id)
    |> QueryHelpers.for_share()
    |> Arca.Repo.one()
    |> is_binary()
  end

  defp declared_restore(slot) do
    with :ok <- slot_holds(slot) do
      case lock_marker() do
        nil ->
          :none

        %ServerMeta{value: restore_id} ->
          change = restore_rows(restore_id)

          with :ok <- restore_holds(restore_id, change.user_ids),
               :ok <- slot_holds(slot) do
            change
          else
            {:error, reason} -> Arca.Repo.rollback(reason)
          end
      end
    else
      {:error, reason} -> Arca.Repo.rollback(reason)
    end
  end

  defp slot_holds(slot) do
    case Arca.ControlPlane.verify_held(slot) do
      :ok -> :ok
      :lost -> {:error, :slot_lost}
    end
  end

  defp lock_marker do
    from(m in ServerMeta, where: m.key == ^@restore_marker)
    |> QueryHelpers.for_update()
    |> Arca.Repo.one()
  end

  # The marker first, then every person and every athanor in id order, as
  # every transition takes people and athanors; then the rows that hang
  # off them in the standing order (the moduledoc's), then the runs.
  # Nothing else takes the marker's row, so taking it first adds no cycle.
  # arca:unscoped-ok a declared restore moves every person, athanor and credential of the server.
  defp restore_rows(restore_id) do
    now = Arca.ServerMetaStorage.now!()
    _user_ids = lock_all(User)
    _athanor_ids = lock_all(Athanor)

    # The people whose methods the restore suspends, read before it does,
    # and those whose methods an earlier restore still holds suspended:
    # each has a passkey or device to re-enable, and only they recover.
    holders = method_holders()

    # An earlier restore's recovery ends here: its rows close as
    # superseded, and its kit credentials and challenges go, so no proof
    # made against the earlier backup re-enables anything after this one.
    superseded = supersede_recoveries(now)

    generations = raise_generations(User, now)
    athanor_generations = raise_generations(Athanor, now)

    {_count, hashes} = Arca.Repo.delete_all(from(s in Session, select: s.token_hash))

    key_ids =
      updated(
        from(k in ApiKey, where: k.revoked == false and k.suspended == false, select: k.id),
        suspended: true,
        updated_at: now
      )

    webhook_ids =
      updated(from(w in Webhook, where: w.suspended == false, select: w.id),
        suspended: true,
        updated_at: now
      )

    frame_ids = FrameCredentials.revoke_all(FrameCredential)

    client_ids =
      updated(from(p in PairedClient, where: p.standing == "active", select: p.id),
        standing: "suspended",
        updated_at: now
      )

    invitation_ids = PairingInvitations.revoke_all(PairingInvitation)
    admission_invitation_ids = Invitations.revoke_all!()

    passkey_ids =
      updated(from(p in Passkey, where: p.state == "active", select: p.id),
        state: "suspended",
        updated_at: now
      )

    confirmation_refs = PendingConfirmations.delete_all!()

    {profile_from, profile_to} = StatusTransitions.restored(:profiles)
    {entry_from, entry_to} = StatusTransitions.restored(:credentials)

    profile_ids =
      updated(from(p in Profile, where: p.status == ^profile_from, select: p.id),
        status: profile_to,
        updated_at: now
      )

    {_count, grant_ids} =
      Arca.Repo.delete_all(from(g in ToolGrant, where: g.effect == "allow", select: g.id))

    {bindings, _} =
      Arca.Repo.update_all(
        from(r in ConsentVaultRef,
          where: r.lifetime_kind == "once" and is_nil(r.consumed_by_root)
        ),
        set: [consumed_by_root: "restore:" <> restore_id]
      )

    approval_ids =
      updated(from(a in Approval, where: a.status == "pending", select: a.id),
        status: "expired",
        resolution_kind: "expired",
        decided_at: now
      )

    vault_ids =
      updated(from(v in VaultEntry, where: v.status == ^entry_from, select: v.id),
        status: entry_to,
        updated_at: now
      )

    # Restored authority never re-enables itself: every share ends, and
    # its owner shares the entry again once they have rotated it.
    {:ok, share_ids} = Arca.Shares.revoke_all(Prima.Actor.system())

    runs = settle_runs(now)

    people = Enum.map(holders, &%{restore_id: restore_id, user_id: &1, open: true})
    Arca.Repo.insert_all(RestorePerson, people, on_conflict: :nothing)

    {1, _} =
      Arca.Repo.delete_all(
        from(m in ServerMeta, where: m.key == ^@restore_marker and m.value == ^restore_id)
      )

    Map.merge(runs, %{
      restore_id: restore_id,
      superseded_restore_ids: superseded,
      user_ids: holders,
      user_generations: generations,
      athanor_generations: athanor_generations,
      revoked_session_hashes: hashes || [],
      suspended_api_key_ids: key_ids,
      suspended_webhook_ids: webhook_ids,
      revoked_frame_credential_ids: frame_ids,
      suspended_paired_client_ids: client_ids,
      revoked_pairing_invitation_ids: invitation_ids,
      revoked_admission_invitation_ids: admission_invitation_ids,
      suspended_passkey_ids: passkey_ids,
      deleted_confirmation_refs: confirmation_refs,
      needs_consent_profile_ids: profile_ids,
      dropped_grant_ids: Enum.sort(grant_ids || []),
      dropped_once_bindings: bindings,
      expired_approval_ids: approval_ids,
      needs_reauth_vault_entry_ids: vault_ids,
      revoked_share_ids: share_ids
    })
  end

  defp lock_all(schema) do
    from(r in schema, order_by: [asc: r.id], select: r.id)
    |> QueryHelpers.for_update()
    |> Arca.Repo.all()
  end

  # Everyone holding a passkey or a paired client that is active, or that
  # an earlier restore suspended and they have not yet re-enabled.
  # arca:unscoped-ok a declared restore reads every person's methods, across every athanor.
  defp method_holders do
    passkeys =
      from(p in Passkey, where: p.state in ["active", "suspended"], select: p.user_id)

    clients =
      from(c in PairedClient,
        where: c.standing in ["active", "suspended"],
        select: c.user_id
      )

    passkeys
    |> union(^clients)
    |> Arca.Repo.all()
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Every open recovery closed, and every kit credential and challenge
  # deleted: what an earlier restore left standing.
  # arca:unscoped-ok a declared restore supersedes every earlier recovery of the server.
  defp supersede_recoveries(now) do
    {_count, closed} =
      Arca.Repo.update_all(
        from(r in RestorePerson, where: r.open == true, select: r.restore_id),
        set: [open: false, closed_at: now]
      )

    kits =
      from(m in ServerMeta,
        where: like(m.key, "restore_kit:%") or like(m.key, ^(@challenge_prefix <> "%"))
      )

    {_count, _} = Arca.Repo.delete_all(kits)
    closed |> List.wrap() |> Enum.uniq() |> Enum.sort()
  end

  defp raise_generations(schema, now) do
    {_count, rows} =
      Arca.Repo.update_all(
        from(r in schema, select: {r.id, r.security_generation}),
        set: [updated_at: now],
        inc: [security_generation: 1]
      )

    Map.new(rows || [])
  end

  defp updated(query, set) do
    {_count, ids} = Arca.Repo.update_all(query, set: set)
    Enum.sort(ids || [])
  end

  # Every open run ends terminal, so boot recovery resumes none: an open
  # execution `failed`, its open attempt `lapsed` with outcome `uncertain`
  # and that attempt's pending write intents `uncertain` (what the sweep's
  # lapse writes, `Arca.ExecutionAttempts.lapse!/3`), and an open turn
  # `uncertain` with each step still proposed or dispatched. The
  # generation raise keeps any successor from taking up the lapsed row.
  # arca:unscoped-ok a declared restore settles every open run of the server.
  defp settle_runs(now) do
    execution_from = Prima.ExecutionState.from(:execution, "failed")
    attempt_from = Prima.ExecutionState.from(:attempt, "lapsed")
    open_turns = Prima.TurnState.open_statuses()

    execution_ids =
      updated(from(e in Execution, where: e.status in ^execution_from, select: e.id),
        status: "failed",
        completed_at: now,
        error_message: "Ended by a declared restore"
      )

    attempt_ids =
      updated(
        from(a in ExecutionAttempt, where: a.state in ^attempt_from, select: a.attempt),
        state: "lapsed",
        outcome: "uncertain",
        running_since: nil,
        ended_at: now
      )

    Arca.Repo.update_all(
      from(i in StorageWriteIntent, where: i.attempt in ^attempt_ids and i.state == "pending"),
      set: [state: "uncertain", reason: "restored", settled_at: now]
    )

    turn_ids =
      updated(from(t in Turn, where: t.status in ^open_turns, select: t.id),
        status: "uncertain",
        ended_at: now
      )

    Arca.Repo.update_all(
      from(s in TurnStep,
        where: s.turn_id in ^turn_ids and s.dispatch_state in ^Prima.TurnState.opening_states()
      ),
      set: [dispatch_state: "uncertain", outcome: "uncertain", ended_at: now]
    )

    %{
      failed_execution_ids: execution_ids,
      lapsed_attempts: attempt_ids,
      uncertain_turn_ids: turn_ids
    }
  end

  # The restore's postconditions, read in its transaction: nothing it
  # moves is left standing, every person holds an open row under it, and
  # its marker is gone.
  # arca:unscoped-ok the postconditions of a declared restore, read across the server.
  defp restore_holds(restore_id, holders) do
    {profile_from, _} = StatusTransitions.restored(:profiles)
    {entry_from, _} = StatusTransitions.restored(:credentials)
    {share_from, _} = StatusTransitions.restored(:shares)

    survivors = [
      Session,
      from(k in ApiKey, where: k.revoked == false and k.suspended == false),
      from(w in Webhook, where: w.suspended == false),
      from(f in FrameCredential, where: f.state != "revoked"),
      from(p in PairedClient, where: p.standing == "active"),
      from(i in PairingInvitation, where: i.state == "pending"),
      from(i in Invitation, where: is_nil(i.redeemed_at) and is_nil(i.revoked_at)),
      from(p in Passkey, where: p.state == "active"),
      PendingConfirmation,
      from(p in Profile, where: p.status == ^profile_from),
      from(g in ToolGrant, where: g.effect == "allow"),
      from(r in ConsentVaultRef, where: r.lifetime_kind == "once" and is_nil(r.consumed_by_root)),
      from(a in Approval, where: a.status == "pending"),
      from(v in VaultEntry, where: v.status == ^entry_from),
      from(s in Share, where: s.status == ^share_from),
      from(e in Execution, where: e.status in ^Prima.ExecutionState.open_statuses()),
      from(a in ExecutionAttempt,
        where: a.state in ^Prima.ExecutionState.open_attempt_states()
      ),
      from(t in Turn, where: t.status in ^Prima.TurnState.open_statuses()),
      from(m in ServerMeta, where: m.key == ^@restore_marker),
      from(r in RestorePerson, where: r.open == true and r.restore_id != ^restore_id),
      from(m in ServerMeta,
        where:
          like(m.key, ^(@credential_prefix <> "%")) or like(m.key, ^(@challenge_prefix <> "%"))
      ),
      from(u in User,
        where:
          u.id in ^holders and
            u.id not in subquery(
              from(r in RestorePerson,
                where: r.restore_id == ^restore_id and r.open == true,
                select: r.user_id
              )
            )
      )
    ]

    if Enum.any?(survivors, &Arca.Repo.exists?/1),
      do: {:error, :postcondition_failed},
      else: :ok
  end

  defp open_rows(user_id) do
    from(r in RestorePerson,
      where: r.user_id == ^user_id and r.open == true,
      order_by: [desc: r.restore_id],
      limit: 1,
      select: r.restore_id
    )
  end

  defp open_row(user_id, restore_id) do
    from(r in RestorePerson,
      where: r.user_id == ^user_id and r.restore_id == ^restore_id and r.open == true
    )
  end

  # arca:unscoped-ok one person's checklist across the athanors they sit in.
  defp checklist(user_id) do
    restore_id = Arca.Repo.one(open_rows(user_id))

    athanor_ids =
      from(m in Membership,
        where: m.user_id == ^user_id and m.scope == "athanor" and m.status == "active",
        select: m.athanor_id
      )

    {_, profile_status} = StatusTransitions.restored(:profiles)
    {_, entry_status} = StatusTransitions.restored(:credentials)

    %{
      restore_id: restore_id,
      restored: Arca.Repo.exists?(from(r in RestorePerson, where: r.user_id == ^user_id)),
      api_keys:
        Arca.Repo.all(
          from(k in ApiKey,
            where: k.created_by == ^user_id and k.suspended == true and k.revoked == false,
            order_by: [asc: k.id],
            select: %{id: k.id, name: k.name, athanor_id: k.athanor_id, prefix: k.key_prefix}
          )
        ),
      webhooks:
        Arca.Repo.all(
          from(w in Webhook,
            where: w.created_by == ^user_id and w.suspended == true,
            order_by: [asc: w.id],
            select: %{id: w.id, name: w.name, athanor_id: w.athanor_id}
          )
        ),
      paired_clients:
        Arca.Repo.all(
          from(p in PairedClient,
            where: p.user_id == ^user_id and p.standing == "suspended",
            order_by: [asc: p.id],
            select: %{id: p.id, athanor_id: p.athanor_id}
          )
        ),
      passkeys:
        Arca.Repo.all(
          from(p in Passkey,
            where: p.user_id == ^user_id and p.state == "suspended",
            order_by: [asc: p.id],
            select: %{id: p.id, rp_id: p.rp_id}
          )
        ),
      profiles:
        Arca.Repo.all(
          from(p in Profile,
            where: p.athanor_id in subquery(athanor_ids) and p.status == ^profile_status,
            order_by: [asc: p.athanor_id, asc: p.id],
            select: %{
              id: p.id,
              athanor_id: p.athanor_id,
              source_ref: p.source_ref,
              label: p.label
            }
          )
        ),
      vault_entries:
        Arca.Repo.all(
          from(v in VaultEntry,
            where: v.athanor_id in subquery(athanor_ids) and v.status == ^entry_status,
            order_by: [asc: v.athanor_id, asc: v.id],
            select: %{id: v.id, athanor_id: v.athanor_id, name: v.name}
          )
        )
    }
  end

  # A kit credential's row, keyed by the bearer's digest: the bearer is
  # random bytes alone (`Prima.CredentialShape`'s `:restore_kit_credential`).
  defp credential_key("sha256:" <> hex), do: @credential_prefix <> hex
  defp credential_key(other), do: @credential_prefix <> other

  # The person's kit credentials, deleted: a new one replaces them, and a
  # closed recovery leaves none.
  # arca:unscoped-ok the restore's credential rows are server facts, read for one person.
  defp drop_credentials!(user_id) do
    held =
      from(m in ServerMeta,
        where: like(m.key, ^(@credential_prefix <> "%")),
        select: {m.key, m.value}
      )
      |> Arca.Repo.all()
      |> Enum.flat_map(fn {key, value} ->
        case Jason.decode(value) do
          {:ok, %{"u" => ^user_id}} -> [key]
          _another -> []
        end
      end)

    if held != [], do: Arca.Repo.delete_all(from(m in ServerMeta, where: m.key in ^held))
    :ok
  end

  # A kit write: under the live ownership fence (`Arca.Repo.owned/2`), one
  # locking transaction with the person's open row under `restore_id`
  # locked first, so a close that commits first refuses it.
  defp kit_write(tag, user_id, restore_id, body) do
    tag
    |> Arca.Repo.owned(fn ->
      locked = open_row(user_id, restore_id) |> QueryHelpers.for_update() |> Arca.Repo.one()

      case if(locked, do: body.(), else: {:error, :closed}) do
        :ok -> {:ok, :ok}
        {:error, _reason} = refusal -> refusal
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, _reason} = refusal -> refusal
    end
  end

  defp challenge_key("sha256:" <> hex), do: @challenge_prefix <> hex
  defp challenge_key(other), do: @challenge_prefix <> other

  defp put_meta(key, value) do
    row = %{key: key, value: Jason.encode!(value), updated_at: Arca.ServerMetaStorage.now!()}

    Arca.Repo.insert_all(ServerMeta, [row],
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :key
    )

    :ok
  end

  # The challenge, deleted as it is read: only a delete that found it
  # redeems it, so two redemptions racing for it never both do.
  defp take_challenge(digest, user_id, restore_id) do
    now = DateTime.to_unix(Arca.ServerMetaStorage.now!(), :millisecond)

    case Arca.Repo.delete_all(
           from(m in ServerMeta, where: m.key == ^challenge_key(digest), select: m.value)
         ) do
      {1, [value]} ->
        case Jason.decode(value) do
          {:ok, %{"u" => ^user_id, "r" => ^restore_id, "e" => expires}}
          when is_integer(expires) and now < expires ->
            :ok

          _another ->
            {:error, :challenge_refused}
        end

      {0, _} ->
        {:error, :challenge_refused}
    end
  end

  # arca:unscoped-ok the restore's challenge rows are server facts, keyed by their digest.
  defp drop_expired_challenges do
    now = DateTime.to_unix(Arca.ServerMetaStorage.now!(), :millisecond)
    prefix = @challenge_prefix <> "%"

    expired =
      from(m in ServerMeta, where: like(m.key, ^prefix), select: {m.key, m.value})
      |> Arca.Repo.all()
      |> Enum.flat_map(fn {key, value} ->
        case Jason.decode(value) do
          {:ok, %{"e" => expires}} when is_integer(expires) and expires > now -> []
          _expired_or_unreadable -> [key]
        end
      end)

    if expired != [], do: Arca.Repo.delete_all(from(m in ServerMeta, where: m.key in ^expired))
    :ok
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

  defp lock_athanors([]), do: %{}

  defp lock_athanors(ids) do
    from(a in Athanor, where: a.id in ^ids, order_by: [asc: a.id])
    |> QueryHelpers.for_update()
    |> Arca.Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  # arca:unscoped-ok the plan of a denial reads one person's memberships across every athanor.
  defp unlocked_rows(user_id),
    do: Arca.Repo.all(from(m in Membership, where: m.user_id == ^user_id))

  # arca:unscoped-ok a denial locks one person's memberships across every athanor.
  defp lock_person_rows(user_id) do
    from(m in Membership, where: m.user_id == ^user_id, order_by: [asc: m.id])
    |> QueryHelpers.for_update()
    |> Arca.Repo.all()
  end

  defp lock_seats(_user_id, nil), do: []

  defp lock_seats(user_id, %Athanor{id: athanor_id}) do
    from(m in Membership,
      where: m.user_id == ^user_id and m.athanor_id == ^athanor_id and m.scope == "athanor",
      order_by: [asc: m.id]
    )
    |> QueryHelpers.for_update()
    |> Arca.Repo.all()
  end

  # ---- the answer ------------------------------------------------------------

  # A transition's answer inside its transaction: the change map it
  # committed, or the rollback of its `{:error, reason}`. Not
  # `Arca.Repo.committed/1`, which takes `{:ok, value}`: a transition's body
  # answers its change bare.
  defp committed_change(%{} = change), do: change
  defp committed_change({:error, reason}), do: Arca.Repo.rollback(reason)

  defp merged_ids(left, right), do: Enum.sort(Enum.uniq(left ++ right))

  # The athanors a statement moved, as they stand after it.
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
      revoked_frame_credential_ids: [],
      revoked_paired_client_ids: [],
      revoked_device_certificate_ids: [],
      revoked_pairing_invitation_ids: [],
      revoked_passkey_ids: [],
      voided_confirmation_ids: [],
      removed_membership_ids: [],
      removed_memberships: [],
      seated_membership_ids: [],
      member_user_ids: %{},
      revoked_share_ids: [],
      ended_offer_ids: [],
      left_shared_thread_ids: [],
      archived_shared_thread_ids: []
    }
  end
end
