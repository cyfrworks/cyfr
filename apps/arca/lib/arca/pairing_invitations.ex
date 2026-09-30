# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PairingInvitations do
  @moduledoc """
  Pairing invitations (`Arca.Schemas.PairingInvitation`), athanor-scoped:
  one bearer invitation to pair a device, stored by the hash of its secret
  and never the secret, with the person and membership it was opened
  under, the client id it reserves for the device that redeems it, its
  audience and its expiry.

  ## Opening

  `open/3` runs in the issuance transaction
  (`Arca.SecurityTransitions.Issuance`): the person, the athanor and the
  membership are locked in the standing order, the caller's `verify`
  closure is asked over them (the seam its fresh confirmation is consumed
  through, so the two commit together), and only then is the invitation
  written, its expiry set on the database's clock and its prospective
  client id reserved.

  ## Redeeming

  `lookup/1` takes the hash alone, before any actor exists, and answers
  routing metadata: where the invitation lives, never authority.
  `consume/4` redeems it under the resolved actor: the person, athanor and
  membership are locked first, the caller's standing verifier asked, the
  invitation locked last and its scope, state and expiry rechecked on the
  database's clock with the member's live ownership, and then the issuance
  closure records the paired client and its certificate and the invitation
  is marked consumed, all in that one transaction. Either write failing
  rolls everything back. A consumed or revoked invitation never reopens.

  A standing transition revokes the pending invitations it retires in its
  own transaction (`Arca.SecurityTransitions`); an allow or a reopen never
  resurrects one.
  """

  import Ecto.Query

  alias Arca.QueryHelpers
  alias Arca.SecurityTransitions.Issuance
  alias Arca.Schemas.PairingInvitation

  @max_lifetime_ms 60 * 60 * 1000

  @typedoc "An invitation row, as a plain map."
  @type row :: map()

  @doc """
  Open an invitation in the actor's athanor: `attrs` names the `:user_id`
  and `:membership_id` it is opened under, the `:secret_hash` of its
  bearer secret (`sha256:<hex>`), the `:audience_home` and its
  `:lifetime_ms`. `verify` is handed the locked rows (and the database's
  time) and answers `:ok` or a refusal that writes nothing. Answers the
  invitation, its `prospective_client_id` reserved.
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
            source: nil
          }

          Issuance.run(targets, verify, fn locked ->
            with :ok <- held(slot) do
              insert(athanor_id, fields, locked.now)
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
  audience_home, state, expires_at}`. Routing metadata, never authority:
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
  Redeem the invitation `secret_hash` names in the actor's athanor (the
  module doc). `verify` is the standing verifier over the locked rows;
  `issue` is handed the invitation as a plain map and answers
  `{:ok, result}` (having recorded the paired client and its certificate)
  or a refusal. Answers `{:ok, result}` once; after that the invitation is
  `:consumed`. Refusals also: `:not_found`, `:revoked`, `:expired`,
  `:not_owner`, the verifier's and the issuance's own.
  """
  @spec consume(
          Prima.Actor.t(),
          String.t(),
          (map() -> :ok | {:error, term()}),
          (map() -> {:ok, term()} | {:error, term()})
        ) :: {:ok, term()} | {:error, term()}
  def consume(%Prima.Actor{athanor_id: athanor_id} = actor, secret_hash, verify, issue)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(secret_hash) and
             is_function(verify, 1) and is_function(issue, 1) do
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
               {:ok, result} <- issue.(Arca.Data.project(current)),
               :ok <- consumed!(current, locked.now) do
            {:ok, result}
          end
        end)
      end
    end)
  end

  def consume(%Prima.Actor{}, _secret_hash, _verify, _issue), do: {:error, :no_athanor}

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
        {:audience_home, Prima.Identity.Encoding.home?(attrs[:audience_home])},
        {:lifetime_ms, is_integer(lifetime) and lifetime > 0 and lifetime <= @max_lifetime_ms}
      ]
      |> Enum.reject(&elem(&1, 1))
      |> Map.new(fn {field, _ok} -> {field, ["is required or malformed"]} end)

    if errors == %{},
      do:
        {:ok,
         Map.take(attrs, [:user_id, :membership_id, :secret_hash, :audience_home, :lifetime_ms])},
      else: {:error, {:invalid, errors}}
  end
end
