# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ApiKeyStorage do
  @moduledoc """
  Storage operations for API keys.

  This module provides the database layer for API key storage.
  It's called by `Sanctum.ApiKey` which handles key generation and hashing.

  Every function that names an athanor takes the `Cyfr.Actor` first and
  matches it in its head, refusing an actor whose athanor is nil or the
  empty string with `{:error, :no_athanor}` before any query.
  `get_key_by_hash/1` and `revoke_all_created_by/1` name no athanor: one
  is the presented secret's own lookup and says so where it stands, the
  other sweeps one person's keys across every estate as part of denying
  them on this server.
  Writes use `insert_all`/`update_all` and trust their caller — they run no
  changeset validation, so callers must validate input first.

  Keys are stored as SHA-256 hashes for indexed lookups.
  Key metadata (name, type, scope, rate_limit, ip_allowlist) is stored as plaintext.

  API keys belong to an athanor. All queries filter by `athanor_id` via
  `where_athanor/2` to enforce tenant isolation. The key hash serves as the
  authentication credential; `athanor_id` is derived from the stored key
  record, not from the request.
  """

  require Logger
  require Arca.Repo.Errors
  import Ecto.Query

  import Arca.QueryHelpers, only: [where_athanor: 2]

  alias Arca.Schemas.ApiKey

  # Columns returned to callers — deliberately excludes the secret `key_hash`
  # (the lookup credential), which no caller needs back from a read.
  @returned_fields [
    :id,
    :name,
    :key_prefix,
    :type,
    :scope,
    :rate_limit,
    :ip_allowlist,
    :revoked,
    :created_by,
    :rotated_at,
    :athanor_id,
    :inserted_at,
    :updated_at
  ]

  @doc """
  Insert a new API key, in the issuance transaction
  (`Arca.SecurityTransitions.Issuance`): `lock:` names the rows the
  creator's standing rests on and `verify:` is the caller's policy over
  them, asked with them locked. `attrs.athanor_id` names the owning
  athanor; `(athanor_id, name)` is unique among unrevoked keys, and a
  violation answers `{:error, :already_exists}`.
  """
  @spec create_key(map(), keyword()) :: :ok | {:error, term()}
  def create_key(attrs, opts) when is_list(opts) do
    lock = Keyword.fetch!(opts, :lock)
    verify = Keyword.fetch!(opts, :verify)

    Arca.SecurityTransitions.Issuance.run(lock, verify, fn _locked -> insert_key(attrs) end)
    |> case do
      {:ok, :inserted} -> :ok
      {:error, _reason} = refusal -> refusal
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      if Arca.Repo.Errors.unique_constraint_violation?(e) do
        {:error, :already_exists}
      else
        Logger.error("[ApiKeyStorage] Database error in create_key: #{Exception.message(e)}")
        {:error, :database_error}
      end
  end

  defp insert_key(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row = %{
      id: Cyfr.UUID7.generate_id("key"),
      name: attrs.name,
      key_hash: attrs.key_hash,
      key_prefix: attrs.key_prefix,
      type: attrs.type,
      scope: attrs[:scope] || "[]",
      rate_limit: attrs[:rate_limit],
      ip_allowlist: attrs[:ip_allowlist],
      capability: attrs[:capability],
      revoked: false,
      created_by: attrs[:created_by],
      rotated_at: nil,
      athanor_id: attrs.athanor_id,
      inserted_at: now,
      updated_at: now
    }

    Arca.Repo.insert_all(ApiKey, [row])
    {:ok, :inserted}
  end

  @doc """
  Whether the named unrevoked key carries a consent capability.

  `capability` is deliberately outside `@returned_fields` — the envelope is
  never part of a read answer — so the one caller that must branch on its
  presence asks for the predicate rather than the value. It gates an
  admission decision, so an unanswerable store refuses rather than defaults.
  """
  @spec capability_bearing?(Cyfr.Actor.t(), String.t()) ::
          {:ok, boolean()} | {:error, :no_athanor | :database_error}
  def capability_bearing?(%Cyfr.Actor{athanor_id: athanor_id}, name)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("ApiKeyStorage.capability_bearing?", fn ->
      found =
        from(k in ApiKey,
          where: k.name == ^name and k.revoked == ^false and not is_nil(k.capability),
          limit: 1,
          select: 1
        )
        |> where_athanor(athanor_id)
        |> Arca.Repo.one()

      {:ok, found != nil}
    end)
  end

  def capability_bearing?(%Cyfr.Actor{}, _name), do: {:error, :no_athanor}

  @doc """
  Get a key by name within an athanor. Excludes revoked keys.

  Returns `{:ok, row}` or `{:error, :not_found}`.
  """
  @spec get_key(Cyfr.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :no_athanor | :not_found | :database_error}
  def get_key(%Cyfr.Actor{athanor_id: athanor_id}, name)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("ApiKeyStorage.get_key", fn ->
      query =
        from(k in ApiKey,
          where: k.name == ^name and k.revoked == ^false,
          limit: 1,
          select: ^@returned_fields
        )
        |> where_athanor(athanor_id)

      case Arca.Repo.one(query) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
    |> Arca.Data.project()
  end

  def get_key(%Cyfr.Actor{}, _name), do: {:error, :no_athanor}

  @doc """
  Get an unrevoked key row by its id within an athanor — the lookup a
  key-authenticated context uses to read its own key's attributes.
  """
  @spec get_key_by_id(Cyfr.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :no_athanor | :not_found | :database_error}
  def get_key_by_id(%Cyfr.Actor{athanor_id: athanor_id}, id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("ApiKeyStorage.get_key_by_id", fn ->
      query =
        from(k in ApiKey, where: k.id == ^id and k.revoked == false)
        |> where_athanor(athanor_id)

      case Arca.Repo.one(query) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
    |> Arca.Data.project()
  end

  def get_key_by_id(%Cyfr.Actor{}, _id), do: {:error, :no_athanor}

  @doc """
  Get a key by its hash. Used for validate() lookups.

  Returns `{:ok, row}` or `{:error, :not_found}`.

  API keys are athanor credentials: `athanor_id` is read back from the
  returned row and the tenant binding is enforced on the resulting
  `Sanctum.Context` (`require_tenant!`), NOT at lookup time. The key hash is a
  192-bit globally-unique credential, so this single untenanted lookup is the
  correct and authoritative path regardless of how the deployment is configured.
  """
  @spec get_key_by_hash(binary()) :: {:ok, map()} | {:error, :not_found | :database_error}
  # arca:unscoped-ok a key hash is a 192-bit globally-unique credential; the
  # athanor comes FROM the row, so there is no context to scope by yet.
  def get_key_by_hash(key_hash) do
    Arca.Repo.Errors.with_db_rescue("ApiKeyStorage.get_key_by_hash", fn ->
      query =
        from(k in ApiKey,
          where: k.key_hash == ^key_hash,
          limit: 1,
          select: ^@returned_fields
        )

      case Arca.Repo.one(query) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
    |> Arca.Data.project()
  end

  @doc """
  List all non-revoked keys of an athanor, sorted by inserted_at.
  """
  @spec list_keys(Cyfr.Actor.t()) :: {:ok, [map()]} | {:error, :no_athanor | :database_error}
  def list_keys(%Cyfr.Actor{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("ApiKeyStorage.list_keys", fn ->
      query =
        from(k in ApiKey,
          where: k.revoked == ^false,
          order_by: [asc: k.inserted_at],
          select: ^@returned_fields
        )
        |> where_athanor(athanor_id)

      {:ok, Arca.Repo.all(query)}
    end)
    |> Arca.Data.project()
  end

  def list_keys(%Cyfr.Actor{}), do: {:error, :no_athanor}

  @doc """
  Revoke a key by name within an athanor.
  """
  @spec revoke_key(Cyfr.Actor.t(), String.t()) ::
          :ok | {:error, :no_athanor | :not_found | :database_error}
  def revoke_key(%Cyfr.Actor{athanor_id: athanor_id}, name)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("ApiKeyStorage.revoke_key", fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      query =
        from(k in ApiKey, where: k.name == ^name and k.revoked == ^false)
        |> where_athanor(athanor_id)

      case Arca.Repo.update_all(query, set: [revoked: true, updated_at: now]) do
        {0, _} -> {:error, :not_found}
        {_, _} -> :ok
      end
    end)
  end

  def revoke_key(%Cyfr.Actor{}, _name), do: {:error, :no_athanor}

  @doc """
  Revoke every live key a person created, across athanors. Returns the count.
  """
  @spec revoke_all_created_by(String.t()) :: {:ok, non_neg_integer()} | {:error, :database_error}
  # arca:unscoped-ok crossing athanors is the point: a person losing standing
  # loses every key they made, wherever they made it.
  def revoke_all_created_by(user_id) when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("ApiKeyStorage.revoke_all_created_by", fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      query = from(k in ApiKey, where: k.created_by == ^user_id and k.revoked == ^false)
      {count, _} = Arca.Repo.update_all(query, set: [revoked: true, updated_at: now])
      {:ok, count}
    end)
  end

  @doc """
  Rotate a key, in the issuance transaction
  (`Arca.SecurityTransitions.Issuance`) under the rotating caller's
  `lock:` and `verify:`: the key's row is locked last and retired —
  revoked, its hash replaced so the old secret matches no row — and a new
  row with the same name and settings carries the new secret. A rotation
  is a new credential: anything bound to the old row's id (a tincture
  token derived from it) is retired with it, and no row that follows can
  take that id back.
  """
  @spec rotate_key(Cyfr.Actor.t(), String.t(), binary(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def rotate_key(%Cyfr.Actor{athanor_id: athanor_id}, name, new_key_hash, new_key_prefix, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_list(opts) do
    lock = Keyword.fetch!(opts, :lock)
    verify = Keyword.fetch!(opts, :verify)

    Arca.Repo.Errors.with_db_rescue("ApiKeyStorage.rotate_key", fn ->
      Arca.SecurityTransitions.Issuance.run(lock, verify, fn _locked ->
        rotate_row(athanor_id, name, new_key_hash, new_key_prefix)
      end)
      |> case do
        {:ok, :rotated} -> :ok
        {:error, _reason} = refusal -> refusal
      end
    end)
  end

  def rotate_key(%Cyfr.Actor{}, _name, _new_key_hash, _new_key_prefix, _opts),
    do: {:error, :no_athanor}

  defp rotate_row(athanor_id, name, new_key_hash, new_key_prefix) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    current =
      from(k in ApiKey, where: k.name == ^name and k.revoked == ^false)
      |> where_athanor(athanor_id)
      |> Arca.QueryHelpers.for_update()
      |> Arca.Repo.one()

    case current do
      nil ->
        {:error, :not_found}

      %ApiKey{} = old ->
        # Retired before its successor is written: the name is unique among
        # unrevoked keys, and the old secret must match no row at all.
        {1, _} =
          from(k in ApiKey, where: k.id == ^old.id and k.athanor_id == ^athanor_id)
          |> Arca.Repo.update_all(
            set: [
              revoked: true,
              key_hash: :crypto.hash(:sha256, "rotated:" <> old.key_hash),
              updated_at: now
            ]
          )

        Arca.Repo.insert_all(ApiKey, [
          %{
            id: Cyfr.UUID7.generate_id("key"),
            name: old.name,
            key_hash: new_key_hash,
            key_prefix: new_key_prefix,
            type: old.type,
            scope: old.scope,
            rate_limit: old.rate_limit,
            ip_allowlist: old.ip_allowlist,
            capability: old.capability,
            revoked: false,
            created_by: old.created_by,
            rotated_at: now,
            athanor_id: athanor_id,
            inserted_at: now,
            updated_at: now
          }
        ])

        {:ok, :rotated}
    end
  end
end
