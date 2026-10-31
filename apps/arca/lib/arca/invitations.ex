# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Invitations do
  @moduledoc """
  Invitations to become a person here (`Arca.Schemas.Invitation`): each
  stored by the hash of its code (`code_hash`, the lowercase hex SHA-256
  of the code's 32 bytes) and never the code, with the person who issued
  it, the group athanor it seats its newcomer in or none, the name it
  offers its newcomer or none, and its expiry.
  Who may issue, revoke or redeem one is `Sanctum.Invitations`'.

  An invitation is bound to its issuer's standing when it was issued:
  `issuer_generation` is their `security_generation` as their row stood
  when it was written, read in the insert's transaction under a shared
  lock on that row and never taken from an argument. A transition that
  raises it and committed first is read there; one that starts later
  waits for the invitation, then raises it past the recorded value.

  ## The first argument

  `insert/2` writes in the actor's athanor: an athanor-scoped actor's
  invitation names that athanor, and the platform scope's names none. The
  athanor comes from the actor, never from an argument. Every other
  function matches `scope: :platform` and refuses an athanor-scoped actor
  with `{:error, :cross_tenant}`: an invitation is found by its code before
  anyone is signed in, listed by its issuer across every athanor it names,
  and redeemed by the admission of a person who holds no athanor yet, so
  none of them can be filtered by one athanor.

  ## Ends

  An invitation ends once. `revoke/2` sets `revoked_at` on an open row,
  one neither redeemed nor revoked, and a declared restore sets it on
  every open row (`revoke_all!/0`). `redeem/3` marks a row redeemed by the
  person only while it is unredeemed, unrevoked and unexpired on the
  database's clock. Each is one conditional write whose row count is its
  answer, so of two redemptions racing for one code one marks it and the
  other finds it redeemed, and the baseline holds the two ends apart
  (`invitations_one_end`).

  A row crosses as a plain map (`Arca.Data`). A refusal is `:not_found`,
  `:redeemed`, `:conflict` (the code's hash is taken),
  `{:invalid, %{field => [message]}}` (an issuer naming no person here
  among them), `:no_athanor`, `:cross_tenant`, `:not_owner` or
  `:database_error`.
  """

  import Ecto.Query

  alias Arca.QueryHelpers
  alias Arca.Schemas.{Invitation, User}

  @typedoc "An invitation row, as a plain map."
  @type row :: map()

  @doc """
  Write an invitation in the actor's athanor (the module doc): `attrs`
  names its `:code_hash`, the person it is `:issued_by`, its
  `:lifetime_ms`, from which its expiry is set on the database's clock,
  and optionally the `:name` it offers its newcomer. The issuer's
  generation is read from their row (the module doc).

  An invitation widens who reaches this CYFR, so it is written only by
  the member holding the control plane's slot (`Arca.Repo.owned/2`).
  """
  @spec insert(Prima.Actor.t(), map()) ::
          {:ok, row()}
          | {:error, :conflict | {:invalid, map()} | :no_athanor | :not_owner | :database_error}
  def insert(%Prima.Actor{} = actor, attrs) when is_map(attrs) do
    with {:ok, athanor_id} <- athanor(actor),
         {:ok, fields} <- fields(Map.new(attrs)) do
      Arca.Repo.owned("Arca.Invitations.insert", fn ->
        with {:ok, generation} <- issuer_generation(fields.issued_by) do
          now = Arca.ServerMetaStorage.now!()

          row = %{
            id: Prima.UUID7.generate_id("inv"),
            code_hash: fields.code_hash,
            issued_by: fields.issued_by,
            issuer_generation: generation,
            athanor_id: athanor_id,
            name: Map.get(fields, :name),
            expires_at: DateTime.add(now, fields.lifetime_ms, :millisecond),
            inserted_at: now,
            updated_at: now
          }

          case Arca.Repo.insert_all(Invitation, [row], on_conflict: :nothing) do
            {1, _} -> {:ok, Arca.Repo.get!(Invitation, row.id)}
            {0, _} -> {:error, :conflict}
          end
        end
      end)
    end
  end

  @doc "The invitation `id` names."
  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :cross_tenant | :database_error}
  # arca:unscoped-ok an invitation is read by its id for its issuer or the
  # platform administrator, whom `Sanctum.Invitations` decides; it may name
  # no athanor at all.
  def get(%Prima.Actor{scope: :platform}, id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Invitations.get", fn ->
      found(Arca.Repo.get(Invitation, id))
    end)
    |> Arca.Data.project()
  end

  def get(%Prima.Actor{}, _id), do: {:error, :cross_tenant}

  @doc """
  The invitation whose code hashes to `code_hash`, read before anyone is
  signed in: what the invitation page shows, and what redemption decides
  on.
  """
  @spec by_code_hash(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :cross_tenant | :database_error}
  # arca:unscoped-ok the pre-authentication read of an invitation by the
  # hash of its bearer code: no actor or athanor exists yet, and the hash is
  # the only key.
  def by_code_hash(%Prima.Actor{scope: :platform}, code_hash) when is_binary(code_hash) do
    Arca.Repo.Errors.with_db_rescue("Arca.Invitations.by_code_hash", fn ->
      found(Arca.Repo.get_by(Invitation, code_hash: code_hash))
    end)
    |> Arca.Data.project()
  end

  def by_code_hash(%Prima.Actor{}, _code_hash), do: {:error, :cross_tenant}

  @doc """
  Every invitation, newest first, or with `issued_by:` the ones that
  person issued.
  """
  @spec list(Prima.Actor.t(), keyword()) ::
          {:ok, [row()]} | {:error, :cross_tenant | :database_error}
  # arca:unscoped-ok an issuer's invitations are listed across every
  # athanor they name, and the platform administrator lists them all.
  def list(%Prima.Actor{scope: :platform}, opts) when is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.Invitations.list", fn ->
      query = from(i in Invitation, order_by: [desc: i.inserted_at, desc: i.id])

      query =
        case Keyword.get(opts, :issued_by) do
          nil -> query
          issued_by when is_binary(issued_by) -> where(query, [i], i.issued_by == ^issued_by)
        end

      {:ok, Arca.Repo.all(query)}
    end)
    |> Arca.Data.project()
  end

  def list(%Prima.Actor{}, _opts), do: {:error, :cross_tenant}

  @doc """
  Revoke the invitation `id`: `revoked_at` is set only on an open row.
  One revoked already answers as it stands; one redeemed is `:redeemed`.
  """
  @spec revoke(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :redeemed | :cross_tenant | :database_error}
  # arca:unscoped-ok an invitation is revoked by its id for its issuer or
  # the platform administrator, whom `Sanctum.Invitations` decides.
  def revoke(%Prima.Actor{scope: :platform}, id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Invitations.revoke", fn ->
      now = Arca.ServerMetaStorage.now!()

      Arca.Repo.update_all(
        from(i in Invitation,
          where: i.id == ^id and is_nil(i.redeemed_at) and is_nil(i.revoked_at)
        ),
        set: [revoked_at: now, updated_at: now]
      )

      case Arca.Repo.get(Invitation, id) do
        nil -> {:error, :not_found}
        %Invitation{redeemed_at: %DateTime{}} -> {:error, :redeemed}
        %Invitation{} = invitation -> {:ok, invitation}
      end
    end)
    |> Arca.Data.project()
  end

  def revoke(%Prima.Actor{}, _id), do: {:error, :cross_tenant}

  @doc """
  Redeem the invitation whose code hashes to `code_hash` for the person
  `user_id`, in the caller's transaction (the admission's mint): one
  conditional write, which marks the row only while it is unredeemed,
  unrevoked and unexpired on the database's clock. Answers the row it
  marked, or `:not_found` when it marked none.
  """
  @spec redeem(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :cross_tenant}
  # arca:unscoped-ok redeemed by the admission of a person who holds no
  # athanor yet, by the hash of the bearer code they present.
  # arca:db-raise-ok a step inside the admission's transaction, whose mint
  # rescues around it.
  def redeem(%Prima.Actor{scope: :platform}, code_hash, user_id)
      when is_binary(code_hash) and is_binary(user_id) do
    now = Arca.ServerMetaStorage.now!()

    marked =
      from(i in Invitation,
        where:
          i.code_hash == ^code_hash and is_nil(i.redeemed_at) and is_nil(i.revoked_at) and
            i.expires_at > ^now,
        select: i.id
      )

    case Arca.Repo.update_all(marked,
           set: [redeemed_by: user_id, redeemed_at: now, updated_at: now]
         ) do
      {1, [id]} -> {:ok, Arca.Data.project(Arca.Repo.get!(Invitation, id))}
      {0, _} -> {:error, :not_found}
    end
  end

  def redeem(%Prima.Actor{}, _code_hash, _user_id), do: {:error, :cross_tenant}

  @doc false
  @spec revoke_all!() :: [String.t()]
  # A declared restore's revocation, in its transaction
  # (`Arca.SecurityTransitions.restore/1`): every open invitation, expired
  # or not, is revoked, so no invitation issued before the backup was taken
  # admits a person after it. Answers the ids revoked, sorted.
  # arca:unscoped-ok a declared restore revokes every open invitation of the server.
  # arca:db-raise-ok a transaction step: its caller rescues around the transaction.
  def revoke_all! do
    now = Arca.ServerMetaStorage.now!()

    {_count, ids} =
      Arca.Repo.update_all(
        from(i in Invitation,
          where: is_nil(i.redeemed_at) and is_nil(i.revoked_at),
          select: i.id
        ),
        set: [revoked_at: now, updated_at: now]
      )

    Enum.sort(ids || [])
  end

  # ---- internals -------------------------------------------------------------

  # The issuer's generation as their row stands, under a shared lock on it
  # (the module doc). A person is locked before their invitations, as
  # every standing transition takes them (`Arca.SecurityTransitions`).
  defp issuer_generation(user_id) do
    from(u in User, where: u.id == ^user_id, select: u.security_generation)
    |> QueryHelpers.for_share()
    |> Arca.Repo.one()
    |> case do
      generation when is_integer(generation) -> {:ok, generation}
      nil -> {:error, {:invalid, %{issued_by: ["names no person here"]}}}
    end
  end

  defp athanor(%Prima.Actor{scope: :platform, athanor_id: nil}), do: {:ok, nil}
  defp athanor(%Prima.Actor{athanor_id: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp athanor(%Prima.Actor{}), do: {:error, :no_athanor}

  defp fields(attrs) do
    lifetime = attrs[:lifetime_ms]

    errors =
      [
        {:code_hash, is_binary(attrs[:code_hash]) and attrs[:code_hash] =~ ~r/\A[0-9a-f]{64}\z/},
        {:issued_by, Prima.PersonId.person?(attrs[:issued_by])},
        {:lifetime_ms, is_integer(lifetime) and lifetime > 0},
        {:name, is_nil(attrs[:name]) or (is_binary(attrs[:name]) and attrs[:name] != "")}
      ]
      |> Enum.reject(&elem(&1, 1))
      |> Map.new(fn {field, _ok} -> {field, ["is required or malformed"]} end)

    if errors == %{},
      do: {:ok, Map.take(attrs, [:code_hash, :issued_by, :lifetime_ms, :name])},
      else: {:error, {:invalid, errors}}
  end

  defp found(nil), do: {:error, :not_found}
  defp found(%Invitation{} = invitation), do: {:ok, invitation}
end
