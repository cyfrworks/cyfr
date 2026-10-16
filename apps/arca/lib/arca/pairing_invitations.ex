# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PairingInvitations do
  @moduledoc """
  Pairing invitations (`Arca.Schemas.PairingInvitation`), athanor-scoped:
  one invitation to pair one device, stored by the hash of its secret and
  never the secret, with the person and membership it was opened under,
  the client id it reserves for the device that redeems it, its audience,
  its expiry, the digest of the one device key that may redeem it
  (`Prima.Device.key_digest/1`) and the passkey or paired client whose
  confirmation opened it.

  ## Opening

  `open/3` runs in the issuance transaction
  (`Arca.SecurityTransitions.Issuance`): the person, the athanor, the
  membership and the credential the opener holds are locked in the
  standing order, the caller's `verify` closure is asked over them (the
  seam its fresh confirmation is consumed through, so the two commit
  together), and only then is the invitation written, its expiry set on
  the database's clock and its prospective client id reserved.

  Its confirmer is read from the consumed confirmation itself, never
  taken from the caller: the passkey whose assertion proved it
  (`confirmed_passkey_id`), else the paired client the proof was given on
  (`confirmed_client_id`). A confirmation attributed to neither opens an
  invitation only while the person's first-method latch is still open
  (`Arca.PersonIdentities.first_method_open?/2`, read under the person's
  lock the opening already holds): the bootstrap of a person who holds no
  passkey and no paired device yet. Once the latch is set, such an open is
  refused `:first_method_used`.

  ## Redeeming

  `lookup/1` takes the hash alone, before any actor exists, and answers
  routing metadata: where the invitation lives, never authority.
  `consume/5` redeems it under the resolved actor: the person, athanor and
  membership are locked first, the caller's standing verifier asked, the
  invitation locked last and its scope, state and expiry rechecked on the
  database's clock with the member's live ownership. Then, before the
  issuance closure runs, the presented key's digest must be the one the
  invitation names (`:key_mismatch`), its confirmer must still stand, the
  passkey active or the paired client active, each locked
  (`:confirmer_revoked`), the invitation still unexpired on the
  database's clock once that lock is won (`:expired`), and the person's
  first-method latch is set: an
  invitation with no confirmer must be the one that sets it, so of two
  bootstrap invitations one alone completes (`:first_method_used`). Then
  the issuance closure records the paired client and its certificate and
  the invitation is marked consumed, all in that one transaction. Any step
  failing rolls everything back, the latch's mark with it. A consumed or
  revoked invitation never reopens.

  A standing transition revokes the pending invitations it retires in its
  own transaction (`Arca.SecurityTransitions`); an allow or a reopen never
  resurrects one.
  """

  import Ecto.Query

  alias Arca.QueryHelpers
  alias Arca.SecurityTransitions.Issuance
  alias Arca.Schemas.{PairedClient, PairingInvitation, Passkey, PendingConfirmation}

  @max_lifetime_ms 60 * 60 * 1000

  @typedoc "An invitation row, as a plain map."
  @type row :: map()

  @doc """
  Open an invitation in the actor's athanor: `attrs` names the `:user_id`
  and `:membership_id` it is opened under, the `:secret_hash` of its
  secret (`sha256:<hex>`), the `:key_digest` of the device key it is for,
  the `:confirmation_ref` of the confirmation `verify` consumes, the
  `:audience_home` and its `:lifetime_ms`, and optionally the `:source`
  credential the opener holds (`t:Arca.SecurityTransitions.Issuance.source/0`),
  locked after the membership. `verify` is handed the locked rows (and
  the database's time) and answers `:ok` or a refusal that writes
  nothing; once it agreed, the confirmation must read consumed, for this
  person and `pairing.begin` (`:confirmation_unconsumed` otherwise), and
  its attribution is the invitation's confirmer (the module doc). Answers
  the invitation, its `prospective_client_id` reserved.
  """
  @spec open(Prima.Actor.t(), map(), (map() -> :ok | {:error, term()})) ::
          {:ok, row()} | {:error, term()}
  def open(%Prima.Actor{athanor_id: athanor_id}, attrs, verify)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) and is_function(verify, 1) do
    with {:ok, fields} <- fields(Map.new(attrs)) do
      Arca.Repo.Errors.with_db_rescue("Arca.PairingInvitations.open", fn ->
        with {:ok, slot} <- Arca.ControlPlane.member_slot() do
          targets = %{
            user_id: fields.user_id,
            athanor_id: athanor_id,
            membership_id: fields.membership_id,
            source: Map.get(attrs, :source)
          }

          Issuance.run(targets, verify, fn locked ->
            with :ok <- held(slot),
                 {:ok, confirmer} <- confirmer(athanor_id, fields) do
              insert(athanor_id, Map.merge(fields, confirmer), locked.now)
            end
          end)
        end
      end)
      |> Arca.Data.project()
    end
  end

  def open(%Prima.Actor{}, _attrs, _verify), do: {:error, :no_athanor}

  @doc """
  Where the invitation whose secret hashes to `secret_hash` lives:
  `%{id, athanor_id, user_id, membership_id, prospective_client_id,
  audience_home, key_digest, state, expires_at}`. Routing metadata, never authority:
  redeeming it is `consume/4`'s decision.
  """
  @spec lookup(String.t()) :: {:ok, map()} | {:error, :not_found | :database_error}
  # arca:unscoped-ok the pre-authentication lookup of an invitation by the hash
  # of its bearer secret: no actor or athanor exists yet, the hash is the only
  # key, and what it answers routes the redemption, which is scoped.
  def lookup(secret_hash) when is_binary(secret_hash) do
    Arca.Repo.Errors.with_db_rescue("Arca.PairingInvitations.lookup", fn ->
      from(i in PairingInvitation,
        where: i.secret_hash == ^secret_hash,
        select: %{
          id: i.id,
          athanor_id: i.athanor_id,
          user_id: i.user_id,
          membership_id: i.membership_id,
          prospective_client_id: i.prospective_client_id,
          audience_home: i.audience_home,
          key_digest: i.key_digest,
          state: i.state,
          expires_at: i.expires_at
        }
      )
      |> Arca.Repo.one()
      |> case do
        nil -> {:error, :not_found}
        routing -> {:ok, routing}
      end
    end)
  end

  @doc """
  Redeem the invitation `secret_hash` names in the actor's athanor for
  the device key whose digest is `key_digest` (the module doc). `verify`
  is the standing verifier over the locked rows; `issue` is handed the
  invitation as a plain map and answers `{:ok, result}` (having recorded
  the paired client and its certificate) or a refusal. Answers
  `{:ok, result}` once; after that the invitation is `:consumed`.
  Refusals also: `:not_found`, `:revoked`, `:expired`, `:key_mismatch`,
  `:confirmer_revoked`, `:first_method_used`, `:no_identity`,
  `:not_owner`, the verifier's and the issuance's own.
  """
  @spec consume(
          Prima.Actor.t(),
          String.t(),
          String.t(),
          (map() -> :ok | {:error, term()}),
          (map() -> {:ok, term()} | {:error, term()})
        ) :: {:ok, term()} | {:error, term()}
  def consume(
        %Prima.Actor{athanor_id: athanor_id} = actor,
        secret_hash,
        key_digest,
        verify,
        issue
      )
      when is_binary(athanor_id) and athanor_id != "" and is_binary(secret_hash) and
             is_binary(key_digest) and is_function(verify, 1) and is_function(issue, 1) do
    Arca.Repo.Errors.with_db_rescue("Arca.PairingInvitations.consume", fn ->
      with {:ok, slot} <- Arca.ControlPlane.member_slot(),
           {:ok, invitation} <- by_hash(actor, secret_hash) do
        targets = %{
          user_id: invitation.user_id,
          athanor_id: athanor_id,
          membership_id: invitation.membership_id,
          source: nil
        }

        Issuance.run(targets, verify, fn locked ->
          with :ok <- held(slot),
               {:ok, current} <- lock_invitation(actor, invitation.id),
               :ok <- redeemable(current, invitation, locked.now),
               :ok <- key_matches(current, key_digest),
               :ok <- confirmer_stands(current),
               :ok <- still_unexpired(current),
               :ok <- latched(current),
               {:ok, result} <- issue.(Arca.Data.project(current)),
               :ok <- consumed!(current, locked.now) do
            # A device paired fresh ends its person's recovery from a
            # declared restore, as a re-enabled one does.
            _closed = Arca.SecurityTransitions.close_restore!(current.user_id)
            {:ok, result}
          end
        end)
      end
    end)
  end

  def consume(%Prima.Actor{}, _secret_hash, _key_digest, _verify, _issue),
    do: {:error, :no_athanor}

  @doc "Revoke the pending invitation `id`; a closed one answers as it is."
  @spec revoke(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :no_athanor | :database_error}
  def revoke(%Prima.Actor{athanor_id: athanor_id} = actor, id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.PairingInvitations.revoke", fn ->
      Arca.Repo.locking_transaction(fn ->
        mine = PairingInvitation |> QueryHelpers.where_tenant(actor) |> where([i], i.id == ^id)

        if Arca.Repo.exists?(mine) do
          _ = revoke_all(mine)
          Arca.Repo.one!(mine)
        else
          Arca.Repo.rollback(:not_found)
        end
      end)
    end)
    |> Arca.Data.project()
  end

  def revoke(%Prima.Actor{}, _id), do: {:error, :no_athanor}

  @doc """
  The invitations of the actor's athanor, newest first, narrowed by
  `user_id:` and `state:` (`:pending`, the default, `:consumed`,
  `:revoked` or `:all`).
  """
  @spec list(Prima.Actor.t(), keyword()) ::
          {:ok, [row()]} | {:error, :no_athanor | :database_error}
  def list(%Prima.Actor{athanor_id: athanor_id} = actor, filters)
      when is_binary(athanor_id) and athanor_id != "" and is_list(filters) do
    Arca.Repo.Errors.with_db_rescue("Arca.PairingInvitations.list", fn ->
      query =
        PairingInvitation
        |> QueryHelpers.where_tenant(actor)
        |> order_by([i], desc: i.inserted_at, desc: i.id)

      query =
        case Keyword.get(filters, :user_id) do
          nil -> query
          user_id -> where(query, [i], i.user_id == ^user_id)
        end

      query =
        case Keyword.get(filters, :state, :pending) do
          :all ->
            query

          state when state in [:pending, :consumed, :revoked] ->
            where(query, [i], i.state == ^Atom.to_string(state))
        end

      {:ok, Arca.Repo.all(query)}
    end)
    |> Arca.Data.project()
  end

  def list(%Prima.Actor{}, _filters), do: {:error, :no_athanor}

  @doc false
  # Revoke every pending invitation `query` names, in the caller's
  # transaction or its own statement, answering the ids it revoked, sorted.
  # The standing transitions run it inside theirs (`Arca.SecurityTransitions`).
  @spec revoke_all(Ecto.Queryable.t()) :: [String.t()]
  # arca:unscoped-ok the caller's query carries its own scope: an athanor or a person.
  # arca:db-raise-ok a transaction step: its callers rescue around it.
  def revoke_all(query) do
    now = Arca.ServerMetaStorage.now!()

    {_count, ids} =
      Arca.Repo.update_all(
        from(i in query, where: i.state == "pending", select: i.id),
        set: [state: "revoked", revoked_at: now, updated_at: now]
      )

    Enum.sort(ids || [])
  end

  # ---- internals -------------------------------------------------------------

  defp by_hash(actor, secret_hash) do
    PairingInvitation
    |> QueryHelpers.where_tenant(actor)
    |> where([i], i.secret_hash == ^secret_hash)
    |> Arca.Repo.one()
    |> case do
      nil -> {:error, :not_found}
      invitation -> {:ok, invitation}
    end
  end

  defp lock_invitation(actor, id) do
    PairingInvitation
    |> QueryHelpers.where_tenant(actor)
    |> where([i], i.id == ^id)
    |> QueryHelpers.for_update()
    |> Arca.Repo.one()
    |> case do
      nil -> {:error, :not_found}
      invitation -> {:ok, invitation}
    end
  end

  # The invitation as it reads under its lock: still pending, unexpired on
  # the database's clock, and still the person and membership the locks
  # were taken for.
  defp redeemable(current, read, now) do
    cond do
      current.state == "consumed" ->
        {:error, :consumed}

      current.state == "revoked" ->
        {:error, :revoked}

      DateTime.compare(current.expires_at, now) != :gt ->
        {:error, :expired}

      current.user_id != read.user_id or current.membership_id != read.membership_id ->
        {:error, :not_found}

      true ->
        :ok
    end
  end

  # Only the key the invitation was opened for redeems it: an invitation
  # that names none, or another, is refused whatever proof came with it.
  defp key_matches(%PairingInvitation{key_digest: expected}, key_digest)
       when is_binary(expected) do
    if Plug.Crypto.secure_compare(expected, key_digest),
      do: :ok,
      else: {:error, :key_mismatch}
  end

  defp key_matches(%PairingInvitation{}, _key_digest), do: {:error, :key_mismatch}

  # The passkey or paired client whose confirmation opened the invitation
  # still stands, read under its lock after the person's: a revocation
  # that committed first refuses the redemption, and one that follows waits
  # for it and then retires the client it paired with the rest. The person
  # is the head of the standing order; a passkey's revocation locks them
  # first too, and a client's locks only its own row.
  defp confirmer_stands(%PairingInvitation{confirmer_kind: nil, confirmer_id: nil}), do: :ok

  defp confirmer_stands(%PairingInvitation{confirmer_kind: "device"} = invitation) do
    from(p in PairedClient,
      where:
        p.athanor_id == ^invitation.athanor_id and p.id == ^invitation.confirmer_id and
          p.user_id == ^invitation.user_id and p.standing == "active",
      select: p.id
    )
    |> standing()
  end

  defp confirmer_stands(%PairingInvitation{confirmer_kind: "passkey"} = invitation) do
    from(p in Passkey,
      where:
        p.id == ^invitation.confirmer_id and p.user_id == ^invitation.user_id and
          p.state == "active",
      select: p.id
    )
    |> standing()
  end

  defp standing(query) do
    if query |> QueryHelpers.for_update() |> Arca.Repo.one() |> is_binary(),
      do: :ok,
      else: {:error, :confirmer_revoked}
  end

  # The confirmer's lock may be waited for after the expiry was read: the
  # invitation is held to its expiry again, on the database's clock, once
  # every lock is won and before anything is issued.
  defp still_unexpired(%PairingInvitation{expires_at: expires_at}) do
    if DateTime.compare(expires_at, Arca.ServerMetaStorage.now!()) == :gt,
      do: :ok,
      else: {:error, :expired}
  end

  # The person's first-method latch is set by this redemption's
  # transaction, under the person's lock it already holds: an invitation
  # opened on a confirmation no passkey or paired client gave completes
  # only as the one that sets it, so a person's bootstrap pairs one device
  # and never reopens; one a passkey or paired client confirmed only keeps
  # the latch set. A redemption that rolls back sets nothing.
  defp latched(%PairingInvitation{user_id: user_id, confirmer_kind: kind}) do
    case {Arca.PersonIdentities.first_method!(user_id), kind} do
      {:marked, _kind} -> :ok
      {:already, nil} -> {:error, :first_method_used}
      {:already, _kind} -> :ok
      {:no_identity, _kind} -> {:error, :no_identity}
    end
  end

  # The confirmer of the invitation about to open: the attribution of the
  # confirmation `verify` consumed, read back from its row in this
  # transaction, never from the caller. One attributed to no passkey and no
  # paired client opens only while the person's latch is open, read under
  # the person's lock the opening holds.
  defp confirmer(athanor_id, fields) do
    from(c in PendingConfirmation,
      where:
        c.athanor_id == ^athanor_id and c.ref == ^fields.confirmation_ref and
          c.user_id == ^fields.user_id and c.operation == "pairing.begin" and
          c.state == "consumed",
      select: %{passkey_id: c.confirmed_passkey_id, client_id: c.confirmed_client_id}
    )
    |> Arca.Repo.one()
    |> case do
      nil ->
        {:error, :confirmation_unconsumed}

      %{passkey_id: passkey_id} when is_binary(passkey_id) ->
        {:ok, %{confirmer_kind: "passkey", confirmer_id: passkey_id}}

      %{client_id: client_id} when is_binary(client_id) ->
        {:ok, %{confirmer_kind: "device", confirmer_id: client_id}}

      %{} ->
        if Arca.Repo.exists?(
             from(p in Arca.Schemas.PersonIdentity,
               where: p.user_id == ^fields.user_id and not is_nil(p.first_method_at)
             )
           ),
           do: {:error, :first_method_used},
           else: {:ok, %{confirmer_kind: nil, confirmer_id: nil}}
    end
  end

  defp consumed!(%PairingInvitation{id: id, athanor_id: athanor_id}, now) do
    {count, _} =
      from(i in PairingInvitation,
        where: i.athanor_id == ^athanor_id and i.id == ^id and i.state == "pending"
      )
      |> Arca.Repo.update_all(set: [state: "consumed", consumed_at: now, updated_at: now])

    if count == 1, do: :ok, else: {:error, :consumed}
  end

  defp insert(athanor_id, fields, now) do
    row = %{
      id: Prima.UUID7.generate_id("pin"),
      athanor_id: athanor_id,
      secret_hash: fields.secret_hash,
      user_id: fields.user_id,
      membership_id: fields.membership_id,
      prospective_client_id: Prima.UUID7.generate_id("pcl"),
      audience_home: fields.audience_home,
      key_digest: fields.key_digest,
      confirmer_kind: fields.confirmer_kind,
      confirmer_id: fields.confirmer_id,
      expires_at: DateTime.add(now, fields.lifetime_ms, :millisecond),
      state: "pending",
      inserted_at: now,
      updated_at: now
    }

    case Arca.Repo.insert_all(PairingInvitation, [row], on_conflict: :nothing) do
      {1, _} -> {:ok, Arca.Repo.get!(PairingInvitation, row.id)}
      {0, _} -> {:error, :conflict}
    end
  end

  # The member's live ownership, inside the issuance transaction: a stale
  # owner opens or redeems nothing.
  defp held(slot) do
    case Arca.ControlPlane.verify_held(slot) do
      :ok -> :ok
      :lost -> {:error, :not_owner}
    end
  end

  defp fields(attrs) do
    lifetime = attrs[:lifetime_ms]

    errors =
      [
        {:user_id, is_binary(attrs[:user_id]) and attrs[:user_id] != ""},
        {:membership_id, is_binary(attrs[:membership_id]) and attrs[:membership_id] != ""},
        {:secret_hash, Prima.Identity.Encoding.digest?(attrs[:secret_hash])},
        {:key_digest, Prima.Device.key_digest?(attrs[:key_digest])},
        {:confirmation_ref, Prima.Confirmation.ref?(attrs[:confirmation_ref])},
        {:audience_home, Prima.Identity.Encoding.home?(attrs[:audience_home])},
        {:lifetime_ms, is_integer(lifetime) and lifetime > 0 and lifetime <= @max_lifetime_ms}
      ]
      |> Enum.reject(&elem(&1, 1))
      |> Map.new(fn {field, _ok} -> {field, ["is required or malformed"]} end)

    if errors == %{},
      do:
        {:ok,
         Map.take(attrs, [
           :user_id,
           :membership_id,
           :secret_hash,
           :key_digest,
           :confirmation_ref,
           :audience_home,
           :lifetime_ms
         ])},
      else: {:error, {:invalid, errors}}
  end
end
