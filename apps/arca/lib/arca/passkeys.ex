# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Passkeys do
  @moduledoc """
  A person's WebAuthn credentials at this relying home
  (`Arca.Schemas.Passkey`): person-scoped, never an athanor's, each pinned
  to the home's RP ID, with its public key, signature counter and standing
  `pending | active | revoked`.

  Arca verifies no assertion: the auth domain does, and records here what
  it decided.

    * **Registration** (`register/3`) writes a credential `pending` (a
      registration awaiting its administrator's authorization, with its
      exact registration digest, proof-of-possession result and expiry) or
      `active` (the person's own fresh proof sufficed).
    * **Activation** (`activate/3`) moves a pending credential to active
      only while it is unexpired on the database's clock and still carries
      the registration digest and `recovery_epoch` the activation names,
      and while the `key_epoch` and `recovery_epoch` it names are the
      cached head's current ones, read under the person's lock, with an
      `also:` closure in which the administrator's confirmation is
      consumed, so activation and authorization commit together.
    * Every credential that becomes active marks the person's
      first-method flag (`Arca.PersonIdentities`), which nothing clears; an
      activation that claims the local first-method exception
      (`first_method: true`) is refused `:first_method_used` once any
      method ever existed.
    * A remote person's credential names the `identity_recovery_epoch` it
      was registered under, which must be the cached head's current
      `recovery_epoch` when it is recorded
      (`Arca.DirectoryHeads.recovery_bindable!/2`, under the person's
      lock), and a recovery that moves that epoch revokes it
      (`revoke_recovery_epoch!/2`); an ordinary rotation does not. A local
      person's names none.
    * **Revocation** is terminal, and voids the pending confirmations the
      credential confirmed (`Arca.PendingConfirmations`). It locks the
      person's row first, as unlinking a door does, and runs the caller's
      `also:` check under that lock.

  Every function takes the actor first: a person reaches their own
  credentials, the platform's own actor any. Registration and activation
  prove first that this member still owns its slot (`:not_owner`); a
  revocation only narrows and is never refused for ownership.
  """

  import Ecto.Query

  alias Arca.{PendingConfirmations, PersonIdentities}
  alias Arca.Schemas.Passkey

  @typedoc "A passkey row, as a plain map."
  @type row :: map()

  @doc """
  Record a credential. `attrs`: `:user_id`, `:credential_id`, `:rp_id`,
  `:relying_home`, `:public_key`, `:registration_digest`,
  `:possession_verified`, `:state` (`"pending"` or `"active"`), `:label`,
  `:expires_at` (required while pending) and `:identity_recovery_epoch`
  (required for a remote person, refused for a local one). `opts`:
  `first_method: true` claims the local first-method exception, and
  `also:` runs in the transaction with the row as a plain map.

  Refusals: `:conflict` (the credential is already live at this RP ID),
  `:first_method_used`, `:identity_key_epoch_required`,
  `:stale_key_epoch`, `:unexpected_key_epoch`, `:no_identity`, `:not_owner`, `:cross_tenant`,
  `{:invalid, errors}`, `:database_error`, or the closure's reason.
  """
  @spec register(Prima.Actor.t(), map(), keyword()) :: {:ok, row()} | {:error, term()}
  def register(%Prima.Actor{} = actor, attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    attrs = Map.new(attrs)

    with :ok <- person(actor, attrs[:user_id]),
         {:ok, row} <- build(attrs) do
      Arca.Repo.Errors.with_db_rescue("Arca.Passkeys.register", fn ->
        fenced(fn -> register_in(row, opts) end)
      end)
      |> Arca.Data.project()
    end
  end

  @doc """
  Activate the pending credential `id`. `opts`: the
  `:registration_digest` it must still carry, the
  `:identity_recovery_epoch` it must still name and the
  `:identity_key_epoch` the authorization was made under (both the cached
  head's current ones, read under the person's lock, and both nil for a
  local person), the `:admin_confirmation_id` whose consumption
  authorizes it, `first_method: true` for the local first-method
  exception, and `also:`, run after the move in the same transaction.
  Refusals: `:not_pending`, `:expired`, `:mismatch`, `:stale_key_epoch`
  (an epoch the cached head no longer names), `:first_method_used`,
  `:not_found`, `:not_owner`, `:cross_tenant`, `:database_error`, or the
  closure's reason.
  """
  @spec activate(Prima.Actor.t(), String.t(), keyword()) :: {:ok, row()} | {:error, term()}
  def activate(%Prima.Actor{} = actor, id, opts) when is_binary(id) and is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.Passkeys.activate", fn ->
      fenced(fn ->
        with {:ok, passkey} <- held(actor, id) do
          # The person first, the head of the standing order, then the
          # credential read again under that lock.
          _locked = Arca.DirectoryHeads.lock_person!(passkey.user_id)
          activate_in(Arca.Repo.get!(Passkey, passkey.id), opts)
        end
      end)
    end)
    |> Arca.Data.project()
  end

  @doc "The credential `id`, if the actor may read it."
  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :cross_tenant | :database_error}
  def get(%Prima.Actor{} = actor, id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Passkeys.get", fn -> held(actor, id) end)
    |> Arca.Data.project()
  end

  @doc """
  The live credential (`pending` or `active`) with `credential_id` at
  `rp_id`: the sign-in lookup, made before any session exists, so only the
  platform's own actor makes it.
  """
  @spec get_by_credential(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :cross_tenant | :database_error}
  def get_by_credential(%Prima.Actor{scope: :platform}, rp_id, credential_id)
      when is_binary(rp_id) and is_binary(credential_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Passkeys.get_by_credential", fn ->
      from(p in Passkey,
        where: p.rp_id == ^rp_id and p.credential_id == ^credential_id and p.state != "revoked"
      )
      |> Arca.Repo.one()
      |> found()
    end)
    |> Arca.Data.project()
  end

  def get_by_credential(%Prima.Actor{}, _rp_id, _credential_id), do: {:error, :cross_tenant}

  @doc """
  The person's credentials, oldest first, narrowed by `state:` (`:active`,
  the default, `:pending`, `:revoked` or `:all`).
  """
  @spec list(Prima.Actor.t(), String.t(), keyword()) ::
          {:ok, [row()]} | {:error, :cross_tenant | :database_error}
  def list(%Prima.Actor{} = actor, user_id, filters \\ [])
      when is_binary(user_id) and is_list(filters) do
    with :ok <- person(actor, user_id) do
      Arca.Repo.Errors.with_db_rescue("Arca.Passkeys.list", fn ->
        {:ok,
         from(p in Passkey,
           where: p.user_id == ^user_id,
           order_by: [asc: p.inserted_at, asc: p.id]
         )
         |> by_state(Keyword.get(filters, :state, :active))
         |> Arca.Repo.all()}
      end)
      |> Arca.Data.project()
    end
  end

  @doc """
  Record a verified assertion's signature counter: the row moves from
  `expected_count` to `new_count` by compare-and-set, only while active.
  Which counts are acceptable is the verifier's decision; this only makes
  two assertions racing on one count unable to both land (`:stale`).
  """
  @spec record_use(Prima.Actor.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, row()} | {:error, :stale | :cross_tenant | :not_found | :database_error}
  def record_use(%Prima.Actor{} = actor, id, expected_count, new_count)
      when is_binary(id) and is_integer(expected_count) and is_integer(new_count) and
             new_count >= 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.Passkeys.record_use", fn ->
      Arca.Repo.locking_transaction(fn ->
        with {:ok, passkey} <- held(actor, id) do
          now = Arca.ServerMetaStorage.now!()

          from(p in Passkey,
            where: p.id == ^passkey.id and p.state == "active" and p.sign_count == ^expected_count
          )
          |> Arca.Repo.update_all(set: [sign_count: new_count, updated_at: now])
          |> case do
            {1, _} -> {:ok, Arca.Repo.get!(Passkey, passkey.id)}
            {0, _} -> {:error, :stale}
          end
        end
        |> committed()
      end)
    end)
    |> Arca.Data.project()
  end

  @doc """
  Revoke the credential `id`, and void the pending confirmations it
  confirmed, in one locking transaction that locks the credential's
  person first, as unlinking a door does (`Arca.Users.unlink_identity/4`),
  so the two serialize on that row and neither decides on a way in the
  other is removing. Revoking a revoked credential answers it as it is.
  `opts[:also]` runs after the revocation, inside the transaction, handed
  `%{passkey: row, was: state}`, the state the credential stood in under
  the lock; it answers `:ok` or `{:error, reason}`, which leaves the
  credential and its confirmations as they were and refuses with that
  reason. Answers `{:ok, %{passkey: row, voided_confirmation_ids: ids}}`.
  """
  @spec revoke(Prima.Actor.t(), String.t(), keyword()) ::
          {:ok, %{passkey: row(), voided_confirmation_ids: [String.t()]}}
          | {:error, :not_found | :cross_tenant | :database_error | term()}
  def revoke(%Prima.Actor{} = actor, id, opts \\ []) when is_binary(id) and is_list(opts) do
    also = Keyword.get(opts, :also, fn _revoked -> :ok end)

    Arca.Repo.Errors.with_db_rescue("Arca.Passkeys.revoke", fn ->
      Arca.Repo.locking_transaction(fn ->
        case held(actor, id) do
          {:ok, passkey} -> committed(revoke_in(passkey, also))
          {:error, reason} -> Arca.Repo.rollback(reason)
        end
      end)
    end)
    |> Arca.Data.project()
  end

  @doc false
  @spec revoke_all(Ecto.Queryable.t()) :: [String.t()]
  # Revoke every live credential `query` names, in the caller's transaction
  # or its own statement, answering the ids it revoked, sorted. The standing
  # transitions run it inside theirs (`Arca.SecurityTransitions`).
  # arca:db-raise-ok a transaction step: its callers rescue around it.
  def revoke_all(query) do
    now = Arca.ServerMetaStorage.now!()

    {_count, ids} =
      Arca.Repo.update_all(
        from(p in query, where: p.state != "revoked", select: p.id),
        set: [state: "revoked", revoked_at: now, updated_at: now]
      )

    Enum.sort(ids || [])
  end

  @doc false
  @spec revoke_recovery_epoch!([String.t()], String.t()) :: [String.t()]
  # The credentials of `user_ids` registered under `recovery_epoch`,
  # revoked when a fresh head's recovery replaced it
  # (`Arca.DirectoryHeads.advance/4`), with the confirmations they
  # confirmed voided.
  # arca:db-raise-ok a transaction step: its callers rescue around the transaction.
  def revoke_recovery_epoch!(user_ids, recovery_epoch)
      when is_list(user_ids) and is_binary(recovery_epoch) do
    ids =
      revoke_all(
        from(p in Passkey,
          where: p.user_id in ^user_ids and p.identity_recovery_epoch == ^recovery_epoch
        )
      )

    PendingConfirmations.void_confirmed_by!(:passkey, ids)
    ids
  end

  # ---- internals -------------------------------------------------------------

  defp register_in(row, opts) do
    also = Keyword.get(opts, :also, fn _passkey -> :ok end)

    with :ok <- Arca.DirectoryHeads.recovery_bindable!(row.user_id, row.identity_recovery_epoch),
         :ok <- first_method(row, opts),
         :ok <- inserted(row) do
      passkey = Arca.Repo.get!(Passkey, row.id)

      case also.(Arca.Data.project(passkey)) do
        :ok -> {:ok, passkey}
        {:error, _reason} = refusal -> refusal
      end
    end
  end

  defp first_method(%{state: "active", user_id: user_id}, opts),
    do: mark_first(user_id, Keyword.get(opts, :first_method, false))

  defp first_method(%{state: "pending"}, _opts), do: :ok

  defp mark_first(user_id, claims_first?) do
    case {PersonIdentities.first_method!(user_id), claims_first?} do
      {:marked, _} -> :ok
      {:already, false} -> :ok
      {:already, true} -> {:error, :first_method_used}
      {:no_identity, _} -> {:error, :no_identity}
    end
  end

  defp inserted(row) do
    case Arca.Repo.insert_all(Passkey, [row], on_conflict: :nothing) do
      {1, _} -> :ok
      {0, _} -> {:error, :conflict}
    end
  end

  defp activate_in(%Passkey{state: "pending"} = passkey, opts) do
    now = Arca.ServerMetaStorage.now!()
    also = Keyword.get(opts, :also, fn _passkey -> :ok end)

    cond do
      DateTime.compare(passkey.expires_at || now, now) != :gt ->
        {:error, :expired}

      passkey.registration_digest != Keyword.get(opts, :registration_digest) or
          passkey.identity_recovery_epoch != Keyword.get(opts, :identity_recovery_epoch) ->
        {:error, :mismatch}

      true ->
        # The epochs the authorization names are the cached head's current
        # ones, read under the person's lock an advance also takes: an
        # authorization made before a rotation or a recovery activates
        # nothing after it.
        with :ok <-
               Arca.DirectoryHeads.recovery_bindable!(
                 passkey.user_id,
                 passkey.identity_recovery_epoch
               ),
             :ok <-
               Arca.DirectoryHeads.bindable!(
                 passkey.user_id,
                 Keyword.get(opts, :identity_key_epoch)
               ),
             :ok <- mark_first(passkey.user_id, Keyword.get(opts, :first_method, false)),
             :ok <- moved_active(passkey, now, Keyword.get(opts, :admin_confirmation_id)) do
          activated = Arca.Repo.get!(Passkey, passkey.id)

          case also.(Arca.Data.project(activated)) do
            :ok -> {:ok, activated}
            {:error, _reason} = refusal -> refusal
          end
        end
    end
  end

  defp activate_in(%Passkey{}, _opts), do: {:error, :not_pending}

  # The person's row first, as every change to a person's ways in locks
  # it, then the credential read again under that lock, so `was` is the
  # state no concurrent revocation or unlinking can still be changing.
  defp revoke_in(passkey, also) do
    Arca.DirectoryHeads.lock_person!(passkey.user_id)
    %Passkey{state: was} = Arca.Repo.get!(Passkey, passkey.id)
    ids = revoke_all(from(p in Passkey, where: p.id == ^passkey.id))
    voided = PendingConfirmations.void_confirmed_by!(:passkey, ids)
    revoked = Arca.Repo.get!(Passkey, passkey.id)

    case also.(%{passkey: Arca.Data.project(revoked), was: was}) do
      :ok -> {:ok, %{passkey: revoked, voided_confirmation_ids: voided}}
      {:error, _reason} = refusal -> refusal
    end
  end

  defp moved_active(passkey, now, admin_confirmation_id) do
    {count, _} =
      from(p in Passkey,
        where:
          p.id == ^passkey.id and p.state == "pending" and
            p.registration_digest == ^passkey.registration_digest
      )
      |> Arca.Repo.update_all(
        set: [
          state: "active",
          expires_at: nil,
          activated_at: now,
          admin_confirmation_id: admin_confirmation_id,
          updated_at: now
        ]
      )

    if count == 1, do: :ok, else: {:error, :not_pending}
  end

  defp held(actor, id) do
    case Arca.Repo.get(Passkey, id) do
      nil ->
        {:error, :not_found}

      passkey ->
        if person(actor, passkey.user_id) == :ok,
          do: {:ok, passkey},
          else: {:error, :cross_tenant}
    end
  end

  defp person(%Prima.Actor{scope: :platform}, _user_id), do: :ok

  defp person(%Prima.Actor{user_id: user_id}, user_id) when is_binary(user_id) and user_id != "",
    do: :ok

  defp person(%Prima.Actor{}, _user_id), do: {:error, :cross_tenant}

  defp by_state(query, :all), do: query

  defp by_state(query, state) when state in [:active, :pending, :revoked],
    do: where(query, [p], p.state == ^Atom.to_string(state))

  defp found(nil), do: {:error, :not_found}
  defp found(%Passkey{} = passkey), do: {:ok, passkey}

  defp build(attrs) do
    state = attrs[:state]

    errors =
      [
        {:user_id, is_binary(attrs[:user_id]) and attrs[:user_id] != ""},
        {:credential_id, is_binary(attrs[:credential_id]) and attrs[:credential_id] != ""},
        {:rp_id, Prima.Identity.Encoding.host?(attrs[:rp_id])},
        {:relying_home, Prima.Identity.Encoding.home?(attrs[:relying_home])},
        {:public_key, is_binary(attrs[:public_key]) and attrs[:public_key] != ""},
        {:registration_digest, Prima.Identity.Encoding.digest?(attrs[:registration_digest])},
        {:possession_verified, attrs[:possession_verified] == true},
        {:state, state in ["pending", "active"]},
        {:expires_at, state != "pending" or match?(%DateTime{}, attrs[:expires_at])}
      ]
      |> Enum.reject(&elem(&1, 1))
      |> Map.new(fn {field, _ok} -> {field, ["is required"]} end)

    if errors == %{} do
      now = DateTime.utc_now()

      {:ok,
       %{
         id: Prima.UUID7.generate_id("psk"),
         user_id: attrs.user_id,
         credential_id: attrs.credential_id,
         rp_id: attrs.rp_id,
         relying_home: attrs.relying_home,
         public_key: attrs.public_key,
         sign_count: Map.get(attrs, :sign_count, 0),
         identity_recovery_epoch: attrs[:identity_recovery_epoch],
         state: state,
         registration_digest: attrs.registration_digest,
         possession_verified: true,
         expires_at: if(state == "pending", do: usec(attrs.expires_at)),
         admin_confirmation_id: nil,
         label: attrs[:label],
         activated_at: if(state == "active", do: now),
         revoked_at: nil,
         inserted_at: now,
         updated_at: now
       }}
    else
      {:error, {:invalid, errors}}
    end
  end

  # A caller's instant stored at the column's microsecond precision,
  # whatever precision it arrived with.
  defp usec(%DateTime{microsecond: {us, _precision}} = at), do: %{at | microsecond: {us, 6}}

  # Registering and activating a credential widen what the person may
  # confirm, so each transaction first proves this member still owns its
  # slot on the database's clock (`Arca.ControlPlane.verify_held/1`).
  defp fenced(write) do
    with {:ok, slot} <- Arca.ControlPlane.member_slot() do
      Arca.Repo.locking_transaction(fn ->
        case Arca.ControlPlane.verify_held(slot) do
          :ok -> committed(write.())
          :lost -> Arca.Repo.rollback(:not_owner)
        end
      end)
    end
  end

  defp committed({:ok, value}), do: value
  defp committed({:error, reason}), do: Arca.Repo.rollback(reason)
end
