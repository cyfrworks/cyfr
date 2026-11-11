# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SecurityTransitions do
  @moduledoc """
  The standing transitions — deny and allow a person, which archive and
  reopen their athanor, and the declared restore —
  each as ONE transaction over every row it must change, or nothing.

  A transition changes a standing and retires what that standing issued:
  a denial marks the person denied and clears their platform
  administrator's mark, archives their own athanor, removes their seats in
  shared threads
  and the invitations their identifier holds there, archives every pair
  they sit in and every shared thread they leave empty, deletes their sessions and revokes the
  keys they created and the keys of their athanor, the frame
  credentials (`Arca.FrameCredentials`), paired clients
  (`Arca.PairedClients`), the passkeys that signed in here among them, and
  device certificates (`Arca.DeviceCertificates`) of the person and of
  their athanor; it withdraws every file offer they sent or that their
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
  their own athanor and nothing else. It never un-revokes, re-creates or re-seats
  anything the retirement took, and it revokes again every frame
  credential, paired client and device certificate the person still
  holds: a frame opened or a client paired under the old standing never
  outlives a change of it.

  A declared restore (`restore/1`) consumes the marker `cyfr restore`
  writes (`mark_restore/1`): it raises every person's and athanor's
  standing, retires every session, suspends every key, webhook and paired
  client, revokes every device certificate and every open
  invitation to become a person here (`Arca.Invitations`), blocks every
  profile and stored credential, revokes every share, drops every
  standing allow, once binding and pending confirmation, and settles
  every open run terminal. It suspends this home's own bindings and no
  account key, which no home holds: a device comes back by a fresh hello,
  a browser by a fresh sign-in, and a key or webhook by its owner's
  re-enable (`restore_checklist/2` lists what is left).

  Every real change of a standing raises the row's `security_generation`
  in the same statement. A credential is issued only against the
  generation its context read (`Arca.SecurityTransitions.Issuance`), so a
  context read before a retirement cannot issue after the restore.

  ## Lock order

  Every transition, and every credential issuance, takes its row locks in
  one order: people sorted by id, athanors sorted by id, then shared
  threads sorted by id
  (`Arca.SharedThreads`) and their people, then cached identity heads, then
  sessions, then API keys, then frame credentials, then paired clients,
  then device certificates, admission invitations
  (`Arca.Invitations`) and pending confirmations, then file
  offers by offer and file name (`Arca.FileOffers`), then shares by id
  and the profiles that depend on them, by athanor and id (`Arca.Shares`,
  `Arca.ConsentStorage`).
  A file offer is written under its two
  people's locks and its athanor's, shared, so it waits for a denial
  holding them, and either sees an offer that landed first.
  An allow, which counts the server's active athanors for its caller,
  takes the server-wide census lock (`Arca.AthanorCensus`)
  after its row locks and right before the caller's policy, as a mint
  takes it after the people it holds. After it it writes only the rows
  it holds and the credentials and clients that hang off them, which no holder of the census lock locks before taking it. A
  transition taking only a suffix of that order never goes back for an
  earlier lock. A declared restore takes its marker's row first, which
  nothing else locks, then every person and every athanor in id order.
  On PostgreSQL the order is the deadlock rule; on SQLite
  the write lock every transaction takes at entry is the lock and the
  order is code order (`Arca.Repo.locking_transaction/2`).

  A denial touches one athanor, the person's own: the one whose
  `owner_user_id` names them, of which there is at most one (a unique
  index), locked right after the person.

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
  transaction.

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
  key, frame credential, paired client and device certificate ids each
  UPDATE returned, the confirmations it
  voided, the athanors archived or reopened with their new generations,
  the person of each archived athanor, the person's generation, and the shares
  it revoked (`revoked_share_ids`). Refusals:
  `:not_found`, `:conflict`, `:postcondition_failed`, `:cross_tenant`,
  `:no_athanor`, `:not_owner`, `:database_error`, or the callback's own
  reason.

  ## The slot

  A denial and an allow run under this member's slot (`slot:`, as
  `Arca.ControlPlane.member_slot/0` answers it), verified as the
  transaction's first step (`Arca.ControlPlane.verify_held/1`) and proved
  on the database's clock at its commit (`Arca.Repo.locking_transaction/2`):
  a member whose slot a successor took or that lapsed before the proof is
  refused `:not_owner` with no standing changed, and a takeover that
  starts after it waits for the transition to commit.
  """

  import Ecto.Query

  alias Arca.QueryHelpers

  alias Arca.{
    AthanorCensus,
    DeviceCertificates,
    FrameCredentials,
    Invitations,
    PairedClients,
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
    PairedClient,
    PendingConfirmation,
    PersonIdentity,
    Profile,
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

  # How long one transaction of a transition may hold its connection
  # (the moduledoc's "The deadline").
  @deadline_ms 60_000
  @open_confirmation ~w(pending confirmed)
  # The declared restore's marker (`mark_restore/1`, `restore/1`).
  @restore_marker "restore_pending"

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
          required(:voided_confirmation_ids) => [String.t()],
          required(:member_user_ids) => %{String.t() => [String.t()]},
          required(:ended_offer_ids) => [String.t()],
          required(:revoked_share_ids) => [String.t()],
          required(:left_shared_thread_ids) => [String.t()],
          required(:archived_shared_thread_ids) => [String.t()]
        }

  @doc """
  Deny the person `user_id` on this server, with everything a denial
  retires (see the module doc), under `opts[:slot]` (the moduledoc's
  "The slot") and `opts[:verify]`. A person already denied is denied again:
  nothing moves their generation, and the retirement is re-run and its
  postconditions checked, so a retry finishes what a failure left.
  """
  @spec deny_user(Prima.Actor.t(), String.t(), keyword()) :: {:ok, change()} | {:error, term()}
  def deny_user(%Prima.Actor{scope: :platform, system: true}, user_id, opts)
      when is_binary(user_id) and user_id != "" and is_list(opts) do
    verify = Keyword.fetch!(opts, :verify)
    slot = Keyword.fetch!(opts, :slot)

    case run("Arca.SecurityTransitions.deny_user", slot, fn -> deny(user_id, verify) end) do
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
  Restore the person `user_id`: their standing and their own athanor when
  it is archived, under `opts[:slot]` (the moduledoc's "The slot") and
  `opts[:verify]`. Their platform administrator's mark, sessions, keys,
  shared-thread seats and invitations the denial took stay taken.
  """
  @spec allow_user(Prima.Actor.t(), String.t(), keyword()) :: {:ok, change()} | {:error, term()}
  def allow_user(%Prima.Actor{scope: :platform, system: true}, user_id, opts)
      when is_binary(user_id) and user_id != "" and is_list(opts) do
    verify = Keyword.fetch!(opts, :verify)
    slot = Keyword.fetch!(opts, :slot)
    run("Arca.SecurityTransitions.allow_user", slot, fn -> allow(user_id, verify) end)
  end

  def allow_user(%Prima.Actor{}, _user_id, _opts), do: {:error, :cross_tenant}

  # ---- the runner ------------------------------------------------------------

  # One transaction within `@deadline_ms` whose first step verifies
  # `slot`, proved at its commit; a raised database error rolls it back and answers
  # `:database_error`.
  defp run(tag, slot, body) do
    tag
    |> Arca.Repo.Errors.with_db_rescue(fn ->
      Arca.Repo.locking_transaction(
        fn ->
          case Arca.ControlPlane.verify_held(slot) do
            :ok -> body.()
            :lost -> Arca.Repo.rollback(:not_owner)
          end
        end,
        timeout: @deadline_ms
      )
    end)
    |> Arca.Data.project()
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
           athanors = lock_owned(user_id),
           identifier = identifier_of(user_id),
           threads = lock_shared_threads(user_id),
           retire = Map.keys(athanors),
           :ok <-
             decide(verify, %{
               transition: :deny_user,
               user: Projection.user(user),
               athanors: athanors |> Map.values() |> Enum.map(&Projection.athanor/1),
               archive: retire
             }) do
        now = Arca.ServerMetaStorage.now!()

        with {:ok, generation, moved?} <- deny_row(user, now),
             {:ok, archived} <- archive_rows(active_ids(retire, athanors), now) do
          hashes = delete_sessions(user_id)
          key_ids = revoke_keys(user_id, retire, now)
          frame_ids = revoke_frames(user_id, retire)
          paired_ids = revoke_paired(user_id, retire)

          %{certificate_ids: cert_ids, session_hashes: cert_hashes} =
            revoke_certificates(user_id, retire)

          # The confirmations are voided only after the clients are revoked:
          # a confirm locks its client, then its record, and the denial takes
          # them in that order too, so neither waits on the other across a
          # lock the other holds.
          dependents = PairedClients.retire_dependents!(paired_ids)
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
                    platform_admin_at: nil,
                    security_generation: generation
                },
                user_generation: generation,
                athanor_generations: archived,
                athanors: moved(athanors, archived, "archived", now),
                archived_athanor_ids: Enum.sort(Map.keys(archived)),
                revoked_session_hashes: Enum.uniq(hashes ++ cert_hashes),
                revoked_api_key_ids: key_ids,
                revoked_frame_credential_ids: frame_ids,
                revoked_paired_client_ids: paired_ids,
                revoked_device_certificate_ids: merged_ids(dependents.certificate_ids, cert_ids),
                voided_confirmation_ids: merged_ids(dependents.confirmation_ids, own),
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
  # athanors, as the standing order takes them. A
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
      set: [status: "denied", denied_at: now, platform_admin_at: nil, updated_at: now],
      inc: [security_generation: 1]
    )
    |> case do
      {1, [generation]} -> {:ok, generation, true}
      _ -> {:error, :conflict}
    end
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

  defp void_confirmations(query), do: PendingConfirmations.void_all(query)

  # arca:unscoped-ok the postconditions of one person's denial, read across every athanor.
  defp deny_holds(user_id, athanor_ids) do
    survivors = [
      from(u in User,
        where: u.id == ^user_id and (u.status != "denied" or not is_nil(u.platform_admin_at))
      ),
      from(s in Session, where: s.user_id == ^user_id),
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
           athanors = lock_owned(user_id),
           athanor = athanors |> Map.values() |> List.first(),
           :ok <- AthanorCensus.lock(),
           :ok <-
             decide(verify, %{
               transition: :allow_user,
               user: Projection.user(user),
               athanor: Projection.athanor(athanor)
             }) do
        now = Arca.ServerMetaStorage.now!()

        with {:ok, generation, moved?} <- allow_row(user, now),
             {:ok, reopened} <- reopen_rows(archived_ids(athanor), now) do
          frame_ids = revoke_frames(user_id, [])
          paired_ids = revoke_paired(user_id, [])
          dependents = PairedClients.retire_dependents!(paired_ids)

          %{certificate_ids: cert_ids, session_hashes: cert_hashes} =
            revoke_certificates(user_id, [])

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
              revoked_session_hashes: Enum.uniq(dependents.session_hashes ++ cert_hashes),
              revoked_frame_credential_ids: frame_ids,
              revoked_paired_client_ids: paired_ids,
              revoked_device_certificate_ids: merged_ids(dependents.certificate_ids, cert_ids),
              voided_confirmation_ids: dependents.confirmation_ids
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
  unrevoked API key, every webhook and every active paired client, the
  passkeys that signed in here among them; revokes every frame
  credential, every device certificate (`Arca.DeviceCertificates`) and
  every open admission invitation (`Arca.Invitations.revoke_all!/0`);
  deletes every pending confirmation
  (`Arca.PendingConfirmations.delete_all!/0`); moves every active profile
  to `needs_consent`, every active vault entry to `needs_reauth` and every
  active share to `revoked` (`Arca.StatusTransitions.restored/1`),
  answering the shares in `revoked_share_ids`; deletes every standing
  allow (`tool_grants` rows of effect `allow`; denies stay);
  drops every unconsumed once binding by consuming it under the restore
  (`consumed_by_root` `restore:<restore id>`); expires every pending
  approval; and settles every open run terminal under
  `Prima.ExecutionState` and `Prima.TurnState`: an execution `failed`,
  its attempt `lapsed` with outcome `uncertain` and the attempt's pending
  write intents `uncertain`, a turn `uncertain` with its open steps. Rows
  already suspended, blocked, revoked or tombstoned keep their state. It
  then deletes the marker it read, so a retry after commit finds no
  marker and moves nothing, and a crash before commit leaves the marker
  for the next boot. A suspended paired client stays suspended: its
  device comes back by a fresh hello, as a new client
  (`Sanctum.DeviceUnlock`), and a passkey by a fresh sign-in
  (`Sanctum.SignIn`).

  Every statement's postcondition is read before commit; a survivor rolls
  the whole transition back as `:postcondition_failed`. A lost slot is
  `:slot_lost`, whether a check found it lost or the commit's proof did
  (`Arca.Repo.locking_transaction/2`); a store that cannot answer,
  `:database_error`.
  """
  @spec restore(keyword()) :: {:ok, map() | :none} | {:error, term()}
  def restore(opts) when is_list(opts) do
    slot = Keyword.fetch!(opts, :slot)

    Arca.Repo.Errors.with_db_rescue("Arca.SecurityTransitions.restore", fn ->
      case Arca.Repo.locking_transaction(fn -> declared_restore(slot) end,
             timeout: @deadline_ms
           ) do
        {:error, :not_owner} -> {:error, :slot_lost}
        answer -> answer
      end
    end)
    |> Arca.Data.project()
  end

  @doc """
  The person's restore checklist: every API key and webhook they created
  that a declared restore holds suspended, and every profile needing
  consent and every vault entry needing re-authentication in their
  athanor. Each item is a plain map of the fields the checklist shows,
  never a hash, a secret or sealed bytes.
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

  defp declared_restore(slot) do
    with :ok <- slot_holds(slot) do
      case lock_marker() do
        nil ->
          :none

        %ServerMeta{value: restore_id} ->
          change = restore_rows(restore_id)

          with :ok <- restore_holds(),
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

    # Every certificate this home issued ends: a device comes back by a
    # fresh hello, which pairs it anew and issues its own.
    %{certificate_ids: certificate_ids} = DeviceCertificates.revoke_all(DeviceCertificate)

    admission_invitation_ids = Invitations.revoke_all!()

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

    {1, _} =
      Arca.Repo.delete_all(
        from(m in ServerMeta, where: m.key == ^@restore_marker and m.value == ^restore_id)
      )

    Map.merge(runs, %{
      restore_id: restore_id,
      user_generations: generations,
      athanor_generations: athanor_generations,
      revoked_session_hashes: hashes || [],
      suspended_api_key_ids: key_ids,
      suspended_webhook_ids: webhook_ids,
      revoked_frame_credential_ids: frame_ids,
      suspended_paired_client_ids: client_ids,
      revoked_device_certificate_ids: certificate_ids,
      revoked_admission_invitation_ids: admission_invitation_ids,
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
        error_message: "Ended by a declared restore",
        error_class: "uncertain"
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
  # moves is left standing, and its marker is gone.
  # arca:unscoped-ok the postconditions of a declared restore, read across the server.
  defp restore_holds do
    {profile_from, _} = StatusTransitions.restored(:profiles)
    {entry_from, _} = StatusTransitions.restored(:credentials)
    {share_from, _} = StatusTransitions.restored(:shares)

    survivors = [
      Session,
      from(k in ApiKey, where: k.revoked == false and k.suspended == false),
      from(w in Webhook, where: w.suspended == false),
      from(f in FrameCredential, where: f.state != "revoked"),
      from(p in PairedClient, where: p.standing == "active"),
      from(c in DeviceCertificate, where: c.state != "revoked"),
      from(i in Invitation, where: is_nil(i.redeemed_at) and is_nil(i.revoked_at)),
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
      from(m in ServerMeta, where: m.key == ^@restore_marker)
    ]

    if Enum.any?(survivors, &Arca.Repo.exists?/1),
      do: {:error, :postcondition_failed},
      else: :ok
  end

  # arca:unscoped-ok one person's checklist, across their own athanor and what they made.
  defp checklist(user_id) do
    athanor_ids =
      from(a in Athanor, where: a.owner_user_id == ^user_id, select: a.id)

    {_, profile_status} = StatusTransitions.restored(:profiles)
    {_, entry_status} = StatusTransitions.restored(:credentials)

    %{
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

  # ---- locks -----------------------------------------------------------------

  defp lock_user(user_id) do
    case from(u in User, where: u.id == ^user_id)
         |> QueryHelpers.for_update()
         |> Arca.Repo.one() do
      nil -> {:error, :not_found}
      %User{} = user -> {:ok, user}
    end
  end

  # The person's own athanor, by its owner, locked: none, or the one the
  # unique index on `owner_user_id` allows.
  defp lock_owned(user_id) do
    from(a in Athanor, where: a.owner_user_id == ^user_id)
    |> QueryHelpers.for_update()
    |> Arca.Repo.all()
    |> Map.new(&{&1.id, &1})
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
      voided_confirmation_ids: [],
      member_user_ids: %{},
      revoked_share_ids: [],
      ended_offer_ids: [],
      left_shared_thread_ids: [],
      archived_shared_thread_ids: []
    }
  end
end
