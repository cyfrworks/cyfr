# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ApiKeyStorage do
  @moduledoc """
  Storage operations for API keys.

  This module provides the database layer for API key storage.
  It's called by `Sanctum.ApiKey` which handles key generation and hashing.
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
  Insert a new API key. `attrs.athanor_id` names the owning athanor;
  `(athanor_id, name)` is unique among unrevoked keys.
  """
  @spec create_key(map()) :: :ok | {:error, term()}
  def create_key(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row = %{
      id: Ecto.UUID.generate(),
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
    :ok
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      if Arca.Repo.Errors.unique_constraint_violation?(e) do
        {:error, :already_exists}
      else
        Logger.error("[ApiKeyStorage] Database error in create_key: #{Exception.message(e)}")
        {:error, :database_error}
      end
  end

  @doc """
  Get a key by name within an athanor. Excludes revoked keys.

  Returns `{:ok, row}` or `{:error, :not_found}`.
  """
  @spec get_key(String.t(), String.t()) :: {:ok, ApiKey.t()} | {:error, :not_found}
  def get_key(name, athanor_id) do
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
  end

  @doc """
  Get an unrevoked key row by its id within an athanor — the lookup a
  key-authenticated context uses to read its own key's attributes.
  """
  @spec get_key_by_id(String.t(), String.t()) ::
          {:ok, ApiKey.t()} | {:error, :not_found | :database_error}
  def get_key_by_id(athanor_id, id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("ApiKeyStorage.get_key_by_id", fn ->
      query =
        from(k in ApiKey, where: k.id == ^id and k.revoked == false)
        |> where_athanor(athanor_id)

      case Arca.Repo.one(query) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
  end

  @doc """
  Get a key by its hash. Used for validate() lookups.

  Returns `{:ok, row}` or `{:error, :not_found}`.

  API keys are athanor credentials: `athanor_id` is read back from the
  returned row and the tenant binding is enforced on the resulting
  `Sanctum.Context` (`require_tenant!`), NOT at lookup time. The key hash is a
  192-bit globally-unique credential, so this single untenanted lookup is the
  correct and authoritative path regardless of how the deployment is configured.
  """
  @spec get_key_by_hash(binary()) :: {:ok, ApiKey.t()} | {:error, :not_found | :database_error}
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
  end

  @doc """
  List all non-revoked keys of an athanor, sorted by inserted_at.
  """
  @spec list_keys(String.t()) :: {:ok, [ApiKey.t()]}
  def list_keys(athanor_id) do
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
  end

  @doc """
  Revoke a key by name within an athanor.
  """
  @spec revoke_key(String.t(), String.t()) :: :ok | {:error, :not_found}
  def revoke_key(name, athanor_id) do
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

  @doc """
  Revoke every live key a person created, across athanors. Returns the count.
  """
  @spec revoke_all_created_by(String.t()) :: {:ok, non_neg_integer()} | {:error, :database_error}
  def revoke_all_created_by(user_id) when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("ApiKeyStorage.revoke_all_created_by", fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      query = from(k in ApiKey, where: k.created_by == ^user_id and k.revoked == ^false)
      {count, _} = Arca.Repo.update_all(query, set: [revoked: true, updated_at: now])
      {:ok, count}
    end)
  end

  @doc """
  Revoke every live key of an athanor. Returns the count.
  """
  @spec revoke_all_for_athanor(String.t()) :: {:ok, non_neg_integer()} | {:error, :database_error}
  def revoke_all_for_athanor(athanor_id) do
    Arca.Repo.Errors.with_db_rescue("ApiKeyStorage.revoke_all_for_athanor", fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      query = from(k in ApiKey, where: k.revoked == ^false) |> where_athanor(athanor_id)
      {count, _} = Arca.Repo.update_all(query, set: [revoked: true, updated_at: now])
      {:ok, count}
    end)
  end

  @doc """
  Rotate a key: update key_hash, key_prefix, and rotated_at.
  """
  @spec rotate_key(String.t(), String.t(), binary(), String.t()) :: :ok | {:error, :not_found}
  def rotate_key(name, athanor_id, new_key_hash, new_key_prefix) do
    Arca.Repo.Errors.with_db_rescue("ApiKeyStorage.rotate_key", fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      query =
        from(k in ApiKey, where: k.name == ^name and k.revoked == ^false)
        |> where_athanor(athanor_id)

      case Arca.Repo.update_all(query,
             set: [
               key_hash: new_key_hash,
               key_prefix: new_key_prefix,
               rotated_at: now,
               updated_at: now
             ]
           ) do
        {0, _} -> {:error, :not_found}
        {_, _} -> :ok
      end
    end)
  end
end
