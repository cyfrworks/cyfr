# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SecurityTransitions do
  @moduledoc """
  The five standing transitions — deny and allow a person, archive and
  reopen an athanor, and a person leaving one athanor — each as ONE
  transaction over every row it must change, or nothing.

  A transition changes a standing and retires what that standing issued:
  a denial marks the person denied, archives their own athanor, every
  frozen athanor they sit in and every group they leave empty, removes
  their memberships, the invitations their address or identifier still
  holds and their thread follows, deletes their sessions and revokes the
  keys they created and the keys of every athanor it archives, the frame
  credentials (`Arca.FrameCredentials`), paired clients
  (`Arca.PairedClients`), device certificates (`Arca.DeviceCertificates`)
  and pending pairing invitations (`Arca.PairingInvitations`) of the
  person and of every athanor it archives, and the person's passkeys
  (`Arca.Passkeys`); it removes the person from every instance entry's
  listed audience (`Arca.InstanceEntries`), withdraws every file offer
  they sent or that an athanor it archives holds, and declines every
  other offer addressed to them (`Arca.FileOffers`), whose snapshots are
  released once it commits. An archive revokes the athanor's keys, frame
  credentials, paired clients, device certificates and pending pairing
  invitations with it, and withdraws the file offers it holds open, so
  the purge that erases an archived athanor meets no open offer.
  Leaving one athanor (`leave_athanor/3`) removes the
  person's membership of it and their follows there, deletes their
  sessions bound to it, and revokes the frame credentials, paired clients,
  device certificates and pending pairing invitations they hold there,
  leaving their other memberships and their identity untouched. A leave
  that leaves a remote person (`Arca.PersonIdentities`, provenance
  `remote`) with no membership row here retires them here with it: their
  cached identity head (`Arca.DirectoryHeads`) goes, and with it every
  session, passkey, frame credential, paired client, device certificate
  and pending pairing invitation of theirs, so nothing they hold here is
  left to ask about a head this home no longer caches. Their person row,
  identity row and API keys stand. Every transition that revokes a client
  or a credential voids the pending confirmations it confirmed
  (`Arca.PendingConfirmations`), and a denial and a leave void the
  person's own open confirmations where they no longer stand. Each
  commits together or not at all: a statement that fails rolls the whole
  transition back and the caller is answered the failure, so a denial can
  never report success with a credential of the person still standing. An allow restores the person's standing and
  their own athanor and seat and nothing else; a reopen restores the
  athanor and nothing else. Neither un-revokes, re-creates or re-seats
  anything the retirement took, and each revokes again every frame
  credential, paired client, device certificate and pending pairing
  invitation the person or the athanor still holds: a frame opened, a
  client paired or an invitation issued under the old standing never
  outlives a change of it.

  Every real change of a standing raises the row's `security_generation`
  in the same statement. A credential is issued only against the
  generation its context read (`Arca.SecurityTransitions.Issuance`), so a
  context read before a retirement cannot issue after the restore.

  ## Lock order

  Every transition, and every credential issuance, takes its row locks in
  one order: any global cap lock the operation needs, people sorted by id,
  athanors sorted by id, then memberships, invitations and follows, then
  cached identity heads, then sessions, then API keys, then frame
  credentials, then paired clients, then device certificates, pairing
  invitations, passkeys and pending confirmations, then instance entry
  audiences, then file offers by offer and file name (`Arca.FileOffers`).
  A writer of a membership row naming a person takes the person's lock
  first (`Arca.Members`), so a seat or a claim racing a leave or a denial
  waits for it, or it for them; a file offer is written under its two
  people's locks and its athanor's, shared, so it waits for a denial or
  an archive holding them, and either sees an offer that landed first.
  A transition taking only a suffix of that order
  never goes back for an earlier lock. On PostgreSQL the order is the deadlock
  rule; on SQLite the write lock every transaction takes at entry is the
  lock and the order is code order (`Arca.Repo.locking_transaction/2`).

  A denial computes the athanors it touches from the person's memberships,
  locks them, then locks the memberships and computes the set again, and
  once more after the caller's policy, right before it writes. A set that
  moved in between (a seat taken while the athanors were being locked, or
  while the policy was asked) rolls the attempt back, because the athanor
  locks cannot be taken after the membership locks; the transition runs
  again, three times at most, and then answers `{:error, :conflict}`. It
  never continues on a partial view. A seat into an athanor the denial
  holds waits for it (`Arca.Members.seat/2` locks the athanor first).

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
  the memberships removed, invitations withdrawn and seats restored, the
  members of each archived athanor, the person's generation, and the
  identifier whose cached head a leave dropped (`dropped_head_identifier`,
  nil when it retired no one). Refusals:
  `:not_found`, `:not_member` (a leave from an athanor the person does not
  sit in), `:dangling_personal_athanor` (a person's own-athanor pointer
  names no row), `:conflict`, `:postcondition_failed`, `:cross_tenant`,
  `:no_athanor`, `:database_error`, or the callback's own reason.
  """

  import Ecto.Query

  alias Arca.QueryHelpers

  alias Arca.{
    DeviceCertificates,
    FrameCredentials,
    PairedClients,
    PairingInvitations,
    Passkeys,
    PendingConfirmations
  }

  alias Arca.Schemas.{
    ApiKey,
    Athanor,
    DeviceCertificate,
    DirectoryHead,
    FileOffer,
    FrameCredential,
    InstanceEntryMember,
    Membership,
    PairedClient,
    PairingInvitation,
    Passkey,
    PendingConfirmation,
    PersonIdentity,
    Session,
    ThreadSubscription,
    User
  }

  alias Arca.SecurityTransitions.Projection

  @attempts 3
  @open_confirmation ~w(pending confirmed)

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
          required(:withdrawn_invitations) => [map()],
          required(:seated_membership_ids) => [String.t()],
          required(:member_user_ids) => %{String.t() => [String.t()]},
          required(:unfollowed) => non_neg_integer(),
          required(:dropped_head_identifier) => String.t() | nil,
          required(:instance_audiences_left) => non_neg_integer(),
          required(:ended_offer_ids) => [String.t()]
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
  is archived, and their seat in it. Sessions, keys, group seats and
  invitations the denial took stay taken.
  """
  @spec allow_user(Prima.Actor.t(), String.t(), keyword()) :: {:ok, change()} | {:error, term()}
  def allow_user(%Prima.Actor{scope: :platform, system: true}, user_id, opts)
      when is_binary(user_id) and user_id != "" and is_list(opts) do
    verify = Keyword.fetch!(opts, :verify)
    run("Arca.SecurityTransitions.allow_user", fn -> allow(user_id, verify) end)
  end

  def allow_user(%Prima.Actor{}, _user_id, _opts), do: {:error, :cross_tenant}

  @doc """
  Archive the athanor `athanor_id`, revoke its keys and withdraw the file
  offers it still holds open. An athanor already archived keeps its
  generation; its keys are revoked and its offers ended again, and
  checked.
  """
  @spec archive_athanor(Prima.Actor.t(), String.t(), keyword()) ::
          {:ok, change()} | {:error, term()}
  def archive_athanor(%Prima.Actor{scope: :platform, system: true}, athanor_id, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_list(opts) do
    verify = Keyword.fetch!(opts, :verify)

    case run("Arca.SecurityTransitions.archive_athanor", fn -> archive(athanor_id, verify) end) do
      {:ok, change} ->
        # As a denial's: the offers the archive withdrew release their
        # snapshots and announce themselves only once it committed.
        {ended, change} = Map.pop(change, :ended_offers, [])
        Arca.FileOffers.after_end(ended)
        {:ok, change}

      refusal ->
        refusal
    end
  end

  def archive_athanor(%Prima.Actor{}, _athanor_id, _opts), do: {:error, :cross_tenant}

  @doc """
  Reopen the archived athanor `athanor_id`. Its revoked keys stay revoked.
  An athanor already active is answered unchanged.
  """
  @spec unarchive_athanor(Prima.Actor.t(), String.t(), keyword()) ::
          {:ok, change()} | {:error, term()}
  def unarchive_athanor(%Prima.Actor{scope: :platform, system: true}, athanor_id, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_list(opts) do
    verify = Keyword.fetch!(opts, :verify)
    run("Arca.SecurityTransitions.unarchive_athanor", fn -> unarchive(athanor_id, verify) end)
  end

  def unarchive_athanor(%Prima.Actor{}, _athanor_id, _opts), do: {:error, :cross_tenant}

  @doc """
  The person `user_id` leaves the actor's athanor, or is removed from it:
  in one transaction their membership of it goes, with their follows
  there, their sessions bound to it, and the frame credentials, paired
  clients, device certificates and pending pairing invitations they hold
  there; the confirmations those clients confirmed and the person's open
  confirmations there are voided. Their other memberships, their identity
  and every other athanor's rows are untouched, and neither the person's
  nor the athanor's generation moves. Refused `:not_member` when the
  person holds no membership of the athanor. Whether a frozen or emptied
  athanor is archived after is the caller's to decide.

  A remote person left with no membership row here, no athanor seat and
  no platform row, is retired here in the same transaction: their cached
  head is dropped after the memberships and before the sessions, and
  every session, passkey, frame credential, paired client, device
  certificate and pending pairing invitation of theirs goes with the
  confirmations those confirmed and their own open ones; the answer names
  the identifier (`dropped_head_identifier`). Their person row, identity
  row and API keys stand. A local person, one whose keys this home
  holds or who has no identity row, is never retired by a leave.
  """
  @spec leave_athanor(Prima.Actor.t(), String.t(), keyword()) ::
          {:ok, change()} | {:error, term()}
  def leave_athanor(%Prima.Actor{athanor_id: athanor_id}, user_id, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(user_id) and user_id != "" and
             is_list(opts) do
    verify = Keyword.fetch!(opts, :verify)
    run("Arca.SecurityTransitions.leave_athanor", fn -> leave(athanor_id, user_id, verify) end)
  end

  def leave_athanor(%Prima.Actor{}, _user_id, _opts), do: {:error, :no_athanor}

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
           planned = athanors_of(user, unlocked_rows(user_id)),
           athanors = lock_athanors(planned),
           :ok <- personal_present(user, athanors),
           rows = lock_person_rows(user_id),
           :ok <- same_set(planned, athanors_of(user, rows)),
           peers = lock_peers(user_id, group_ids(athanors)),
           identifier = identifier_of(user_id),
           invitations = lock_invitations(user.email, identifier),
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
           :ok <- same_set(planned, athanors_of(user, lock_person_rows(user_id))) do
        now = Arca.ServerMetaStorage.now!()

        with {:ok, generation, moved?} <- deny_row(user, now),
             {:ok, archived} <- archive_rows(active_ids(retire, athanors), now) do
          removed = delete_person_rows(user_id)
          withdrawn = delete_invitations(user.email, identifier)
          unfollowed = delete_follows(user_id, planned)
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
          audiences_left = Arca.InstanceEntries.remove_person!(user_id)
          ended_offers = Arca.FileOffers.end_for_person!(user_id, retire)

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
                revoked_frame_credential_ids: frame_ids,
                revoked_paired_client_ids: paired_ids,
                revoked_device_certificate_ids: merged_ids(dependents.certificate_ids, cert_ids),
                revoked_pairing_invitation_ids: invitation_ids,
                revoked_passkey_ids: passkey_ids,
                voided_confirmation_ids:
                  merged_ids(dependents.confirmation_ids, merged_ids(by_passkeys, own)),
                removed_membership_ids: Enum.map(removed, & &1.id),
                removed_memberships: removed,
                withdrawn_invitations: withdrawn,
                member_user_ids: members_by_athanor(Map.keys(archived), peers),
                unfollowed: unfollowed,
                instance_audiences_left: audiences_left,
                ended_offer_ids:
                  ended_offers |> Enum.map(& &1.offer_id) |> Enum.uniq() |> Enum.sort()
            }
            |> Map.put(:ended_offers, ended_offers)
          end
        end
      end

    committed(result)
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

  defp group_ids(athanors) do
    for {id, %Athanor{kind: "group"}} <- athanors, do: id
  end

  # What a denial archives, under the policy every leave follows: the
  # person's own athanor; a frozen athanor the moment anyone leaves it; an
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

  # arca:unscoped-ok invitations are keyed by address or identifier, across every athanor that holds one.
  defp delete_invitations(email, identifier) do
    case invited_query(email, identifier) do
      nil ->
        []

      query ->
        {_count, rows} =
          Arca.Repo.delete_all(from(m in query, select: %{id: m.id, athanor_id: m.athanor_id}))

        Enum.sort_by(rows || [], & &1.id)
    end
  end

  # The invitations a person's address or identifier still holds, or nil
  # when they have neither.
  defp invited_query(email, identifier) do
    email = if is_binary(email) and email != "", do: email
    identifier = if is_binary(identifier) and identifier != "", do: identifier

    base = from(m in Membership, where: m.status == "invited" and m.scope == "athanor")

    case {email, identifier} do
      {nil, nil} ->
        nil

      {email, nil} ->
        where(base, [m], m.email == ^email)

      {nil, identifier} ->
        where(base, [m], m.person_identifier == ^identifier)

      {email, identifier} ->
        where(base, [m], m.email == ^email or m.person_identifier == ^identifier)
    end
  end

  defp identifier_of(user_id) do
    Arca.Repo.one(from(p in PersonIdentity, where: p.user_id == ^user_id, select: p.identifier))
  end

  defp delete_follows(_user_id, []), do: 0

  # arca:unscoped-ok a denial drops one person's follows in every athanor it touches.
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
      from(m in InstanceEntryMember, where: m.user_id == ^user_id),
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

  defp members_by_athanor(athanor_ids, peers) do
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
          key_ids = revoke_athanor_keys(athanor_id, now)
          frame_ids = revoke_athanor_frames(athanor_id)
          paired_ids = revoke_athanor_paired(athanor_id)
          dependents = PairedClients.retire_dependents!(paired_ids)
          cert_ids = revoke_athanor_certificates(athanor_id)
          invitation_ids = revoke_athanor_invitations(athanor_id)
          ended_offers = Arca.FileOffers.end_for_athanor!(Prima.Actor.in_athanor(athanor_id))

          with :ok <- archive_holds(athanor_id) do
            %{
              empty_change()
              | transitioned: archived != %{},
                athanor_generations: archived,
                athanors: moved(%{athanor_id => athanor}, archived, "archived", now),
                archived_athanor_ids: Map.keys(archived),
                revoked_api_key_ids: key_ids,
                revoked_frame_credential_ids: frame_ids,
                revoked_paired_client_ids: paired_ids,
                revoked_device_certificate_ids: merged_ids(dependents.certificate_ids, cert_ids),
                revoked_pairing_invitation_ids: invitation_ids,
                voided_confirmation_ids: dependents.confirmation_ids,
                member_user_ids: %{athanor_id => members},
                ended_offer_ids:
                  ended_offers |> Enum.map(& &1.offer_id) |> Enum.uniq() |> Enum.sort()
            }
            |> Map.put(:ended_offers, ended_offers)
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
          frame_ids = revoke_athanor_frames(athanor_id)
          paired_ids = revoke_athanor_paired(athanor_id)
          dependents = PairedClients.retire_dependents!(paired_ids)
          cert_ids = revoke_athanor_certificates(athanor_id)
          invitation_ids = revoke_athanor_invitations(athanor_id)

          %{
            empty_change()
            | transitioned: reopened != %{},
              athanor_generations: reopened,
              athanors: moved(%{athanor_id => athanor}, reopened, "active", now),
              reopened_athanor_ids: Map.keys(reopened),
              revoked_frame_credential_ids: frame_ids,
              revoked_paired_client_ids: paired_ids,
              revoked_device_certificate_ids: merged_ids(dependents.certificate_ids, cert_ids),
              revoked_pairing_invitation_ids: invitation_ids,
              voided_confirmation_ids: dependents.confirmation_ids
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

  defp revoke_athanor_keys(athanor_id, now) do
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

  defp revoke_athanor_frames(athanor_id),
    do:
      FrameCredentials.revoke_all(from(f in FrameCredential, where: f.athanor_id == ^athanor_id))

  defp revoke_athanor_paired(athanor_id),
    do: PairedClients.revoke_all(from(p in PairedClient, where: p.athanor_id == ^athanor_id))

  defp revoke_athanor_certificates(athanor_id) do
    DeviceCertificates.revoke_all(
      from(c in DeviceCertificate, where: c.athanor_id == ^athanor_id)
    )
  end

  defp revoke_athanor_invitations(athanor_id) do
    PairingInvitations.revoke_all(
      from(i in PairingInvitation, where: i.athanor_id == ^athanor_id)
    )
  end

  defp archive_holds(athanor_id) do
    survivors = [
      from(a in Athanor, where: a.id == ^athanor_id and a.status != "archived"),
      from(k in ApiKey, where: k.athanor_id == ^athanor_id and k.revoked == false),
      from(f in FrameCredential, where: f.athanor_id == ^athanor_id and f.state != "revoked"),
      from(p in PairedClient, where: p.athanor_id == ^athanor_id and p.standing != "revoked"),
      from(c in DeviceCertificate, where: c.athanor_id == ^athanor_id and c.state != "revoked"),
      from(i in PairingInvitation, where: i.athanor_id == ^athanor_id and i.state == "pending"),
      from(o in FileOffer, where: o.athanor_id == ^athanor_id and o.status == "offered")
    ]

    if Enum.any?(survivors, &Arca.Repo.exists?/1),
      do: {:error, :postcondition_failed},
      else: :ok
  end

  # ---- leave -----------------------------------------------------------------

  defp leave(athanor_id, user_id, verify) do
    result =
      with user = held_user(user_id),
           {:ok, athanor} <- lock_athanor(athanor_id),
           {seats, others} =
             Enum.split_with(
               lock_person_rows(user_id),
               &(&1.athanor_id == athanor_id and &1.scope == "athanor")
             ),
           :ok <- if(seats == [], do: {:error, :not_member}, else: :ok),
           retiring = retiring_identifier(user_id, others),
           :ok <-
             decide(verify, %{
               transition: :leave_athanor,
               user: Projection.user(user),
               athanor: Projection.athanor(athanor),
               memberships: Enum.map(seats, &Projection.membership/1)
             }) do
        reach = if retiring, do: :person, else: {:athanor, athanor_id}
        removed = delete_seats(user_id, athanor_id)
        unfollowed = delete_follows(user_id, [athanor_id])
        :ok = drop_head(retiring)
        hashes = delete_held_sessions(held(Session, user_id, reach))
        frame_ids = FrameCredentials.revoke_all(held(FrameCredential, user_id, reach))
        paired_ids = PairedClients.revoke_all(held(PairedClient, user_id, reach))
        cert_ids = DeviceCertificates.revoke_all(held(DeviceCertificate, user_id, reach))
        invitation_ids = PairingInvitations.revoke_all(held(PairingInvitation, user_id, reach))
        passkey_ids = revoke_held_passkeys(user_id, reach)
        # The confirmations last, after the passkeys, in the order a
        # denial takes them (`deny/2`).
        dependents = PairedClients.retire_dependents!(paired_ids)
        by_passkeys = PendingConfirmations.void_confirmed_by!(:passkey, passkey_ids)
        own = void_confirmations(held(PendingConfirmation, user_id, reach))

        with :ok <- leave_holds(user_id, athanor_id, reach, retiring) do
          %{
            empty_change()
            | transitioned: true,
              user: Projection.user(user),
              revoked_session_hashes: hashes,
              revoked_frame_credential_ids: frame_ids,
              revoked_paired_client_ids: paired_ids,
              revoked_device_certificate_ids: merged_ids(dependents.certificate_ids, cert_ids),
              revoked_pairing_invitation_ids: invitation_ids,
              revoked_passkey_ids: passkey_ids,
              voided_confirmation_ids:
                merged_ids(dependents.confirmation_ids, merged_ids(by_passkeys, own)),
              removed_membership_ids: Enum.map(removed, & &1.id),
              removed_memberships: removed,
              unfollowed: unfollowed,
              dropped_head_identifier: retiring
          }
        end
      end

    committed(result)
  end

  # The leaving person's row, locked, or nil: a membership names its person
  # by id under no foreign key, and a seat naming no person row is still
  # one to leave. Such a seat's leave retires no one, there being no
  # identity row to name them remote.
  defp held_user(user_id) do
    case lock_user(user_id) do
      {:ok, user} -> user
      {:error, :not_found} -> nil
    end
  end

  # The identifier of a remote person this leave leaves with no membership
  # row here, read under the person's lock, or nil: a person with another
  # row, a local person and one with no identity row are not retired.
  defp retiring_identifier(user_id, []) do
    Arca.Repo.one(
      from(p in PersonIdentity,
        where: p.user_id == ^user_id and p.provenance == "remote",
        select: p.identifier
      )
    )
  end

  defp retiring_identifier(_user_id, _other_rows), do: nil

  # What a leave takes of the person's rows in `schema`: what they hold in
  # the athanor they leave, or everything they hold here when the leave
  # retires them.
  defp held(schema, user_id, :person), do: from(r in schema, where: r.user_id == ^user_id)

  defp held(schema, user_id, {:athanor, athanor_id}),
    do: from(r in schema, where: r.user_id == ^user_id and r.athanor_id == ^athanor_id)

  defp delete_seats(user_id, athanor_id) do
    {_count, rows} =
      Arca.Repo.delete_all(
        from(m in Membership,
          where: m.user_id == ^user_id and m.athanor_id == ^athanor_id and m.scope == "athanor",
          select: %{id: m.id, athanor_id: m.athanor_id, scope: m.scope}
        )
      )

    Enum.sort_by(rows || [], & &1.id)
  end

  # A retired remote person's cached head: dropped in the transaction that
  # retires every credential that could ask about it.
  defp drop_head(nil), do: :ok

  defp drop_head(identifier) do
    Arca.Repo.delete_all(from(h in DirectoryHead, where: h.identifier == ^identifier))
    :ok
  end

  # arca:unscoped-ok a leave ends the sessions its query names: those bound to the athanor, or all a retired person holds.
  defp delete_held_sessions(query) do
    {_count, hashes} = Arca.Repo.delete_all(from(s in query, select: s.token_hash))
    hashes || []
  end

  # A passkey is the person's, not an athanor's: only a leave that retires
  # the person here revokes them.
  defp revoke_held_passkeys(user_id, :person),
    do: Passkeys.revoke_all(from(p in Passkey, where: p.user_id == ^user_id))

  defp revoke_held_passkeys(_user_id, {:athanor, _athanor_id}), do: []

  # arca:unscoped-ok the postconditions of one person's leave, read across what it retired.
  defp leave_holds(user_id, athanor_id, reach, retiring) do
    survivors =
      [
        from(m in Membership,
          where: m.user_id == ^user_id and m.athanor_id == ^athanor_id and m.scope == "athanor"
        ),
        held(Session, user_id, reach),
        from(f in held(FrameCredential, user_id, reach), where: f.state != "revoked"),
        from(p in held(PairedClient, user_id, reach), where: p.standing != "revoked"),
        from(c in held(DeviceCertificate, user_id, reach), where: c.state != "revoked"),
        from(i in held(PairingInvitation, user_id, reach), where: i.state == "pending"),
        from(c in held(PendingConfirmation, user_id, reach),
          where: c.state in ^@open_confirmation
        )
      ] ++ retired_survivors(user_id, retiring)

    if Enum.any?(survivors, &Arca.Repo.exists?/1),
      do: {:error, :postcondition_failed},
      else: :ok
  end

  defp retired_survivors(_user_id, nil), do: []

  defp retired_survivors(user_id, identifier) do
    [
      from(h in DirectoryHead, where: h.identifier == ^identifier),
      from(p in Passkey, where: p.user_id == ^user_id and p.state != "revoked")
    ]
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

  # arca:unscoped-ok the plan of a denial reads one person's memberships across every athanor.
  defp unlocked_rows(user_id),
    do: Arca.Repo.all(from(m in Membership, where: m.user_id == ^user_id))

  # arca:unscoped-ok a denial locks one person's memberships across every athanor.
  defp lock_person_rows(user_id) do
    from(m in Membership, where: m.user_id == ^user_id, order_by: [asc: m.id])
    |> QueryHelpers.for_update()
    |> Arca.Repo.all()
  end

  # The other active members of the groups a denial touches: whether a
  # group is left empty is decided on them.
  defp lock_peers(_user_id, []), do: []

  # arca:unscoped-ok the rosters of the groups a denial touches, athanors the caller named.
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

  # arca:unscoped-ok invitations are keyed by address or identifier, across every athanor that holds one.
  defp lock_invitations(email, identifier) do
    case invited_query(email, identifier) do
      nil ->
        []

      query ->
        from(m in query, order_by: [asc: m.id])
        |> QueryHelpers.for_update()
        |> Arca.Repo.all()
    end
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
      withdrawn_invitations: [],
      seated_membership_ids: [],
      member_user_ids: %{},
      unfollowed: 0,
      dropped_head_identifier: nil,
      instance_audiences_left: 0,
      ended_offer_ids: []
    }
  end
end
