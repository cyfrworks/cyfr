defmodule Arca.ApiKeyStorage do
  @moduledoc """
  SQLite storage operations for API keys.

  This module provides the database layer for API key storage.
  It's called by `Sanctum.ApiKey` which handles key generation and hashing.

  Keys are stored as SHA-256 hashes for indexed lookups.
  Key metadata (name, type, scope, rate_limit, ip_allowlist) is stored as plaintext.

  API keys are org-scoped by design. All queries filter by `org_id` via
  `where_org_id/2` to enforce tenant isolation in Arx mode. The key hash
  serves as the authentication credential; `org_id` is derived from the
  stored key record, not from the request.
  """

  require Logger
  require Arca.Repo.Errors
  import Ecto.Query
  import Arca.QueryHelpers, only: [normalize_org_id: 1, where_org_id: 2]

  @doc """
  Insert a new API key.
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
      revoked: false,
      created_by: attrs[:created_by],
      rotated_at: nil,
      scope_type: attrs.scope_type,
      org_id: normalize_org_id(attrs[:org_id]),
      inserted_at: now,
      updated_at: now
    }

    Arca.Repo.insert_all("api_keys", [row])
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
  Get a key by name, scope_type, and org_id. Excludes revoked keys.

  Returns `{:ok, row}` or `{:error, :not_found}`.
  """
  @spec get_key(String.t(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, :not_found}
  def get_key(name, scope_type, org_id) do
    query =
      from(k in "api_keys",
        where: k.name == ^name and k.scope_type == ^scope_type and k.revoked == ^false,
        limit: 1,
        select: %{
          id: k.id,
          name: k.name,
          key_prefix: k.key_prefix,
          type: k.type,
          scope: k.scope,
          rate_limit: k.rate_limit,
          ip_allowlist: k.ip_allowlist,
          revoked: k.revoked,
          created_by: k.created_by,
          rotated_at: k.rotated_at,
          scope_type: k.scope_type,
          org_id: k.org_id,
          inserted_at: k.inserted_at,
          updated_at: k.updated_at
        }
      )

    query = where_org_id(query, org_id)

    case Arca.Repo.one(query) do
      nil -> {:error, :not_found}
      row -> {:ok, normalize_row(row)}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[ApiKeyStorage] Database error in get_key: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Get a key by its hash. Used for validate() lookups.

  Returns `{:ok, row}` or `{:error, :not_found}`.
  """
  @spec get_key_by_hash(binary()) :: {:ok, map()} | {:error, :not_found}
  def get_key_by_hash(key_hash) do
    query =
      from(k in "api_keys",
        where: k.key_hash == ^key_hash,
        limit: 1,
        select: %{
          id: k.id,
          name: k.name,
          key_prefix: k.key_prefix,
          type: k.type,
          scope: k.scope,
          rate_limit: k.rate_limit,
          ip_allowlist: k.ip_allowlist,
          revoked: k.revoked,
          created_by: k.created_by,
          rotated_at: k.rotated_at,
          scope_type: k.scope_type,
          org_id: k.org_id,
          inserted_at: k.inserted_at,
          updated_at: k.updated_at
        }
      )

    case Arca.Repo.one(query) do
      nil -> {:error, :not_found}
      row -> {:ok, normalize_row(row)}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[ApiKeyStorage] Database error in get_key_by_hash: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Get a key by its hash, verifying it belongs to the given org_id.

  Used for Arx multi-tenant validation — ensures a key from org A
  cannot authenticate against org B.

  Returns `{:ok, row}` or `{:error, :not_found}`.
  """
  @spec get_key_by_hash(binary(), String.t() | nil) :: {:ok, map()} | {:error, :not_found}
  def get_key_by_hash(key_hash, org_id) do
    query =
      from(k in "api_keys",
        where: k.key_hash == ^key_hash,
        limit: 1,
        select: %{
          id: k.id,
          name: k.name,
          key_prefix: k.key_prefix,
          type: k.type,
          scope: k.scope,
          rate_limit: k.rate_limit,
          ip_allowlist: k.ip_allowlist,
          revoked: k.revoked,
          created_by: k.created_by,
          rotated_at: k.rotated_at,
          scope_type: k.scope_type,
          org_id: k.org_id,
          inserted_at: k.inserted_at,
          updated_at: k.updated_at
        }
      )

    query = where_org_id(query, org_id)

    case Arca.Repo.one(query) do
      nil -> {:error, :not_found}
      row -> {:ok, normalize_row(row)}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[ApiKeyStorage] Database error in get_key_by_hash/2: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  List all non-revoked keys for a given scope_type and org_id, sorted by inserted_at.
  """
  @spec list_keys(String.t(), String.t() | nil) :: {:ok, [map()]}
  def list_keys(scope_type, org_id) do
    query =
      from(k in "api_keys",
        where: k.scope_type == ^scope_type and k.revoked == ^false,
        order_by: [asc: k.inserted_at],
        select: %{
          id: k.id,
          name: k.name,
          key_prefix: k.key_prefix,
          type: k.type,
          scope: k.scope,
          rate_limit: k.rate_limit,
          ip_allowlist: k.ip_allowlist,
          revoked: k.revoked,
          created_by: k.created_by,
          rotated_at: k.rotated_at,
          scope_type: k.scope_type,
          org_id: k.org_id,
          inserted_at: k.inserted_at,
          updated_at: k.updated_at
        }
      )

    query = where_org_id(query, org_id)

    {:ok, Enum.map(Arca.Repo.all(query), &normalize_row/1)}
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[ApiKeyStorage] Database error in list_keys: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Revoke a key by name, scope_type, and org_id.
  """
  @spec revoke_key(String.t(), String.t(), String.t() | nil) :: :ok | {:error, :not_found}
  def revoke_key(name, scope_type, org_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    query =
      from(k in "api_keys",
        where: k.name == ^name and k.scope_type == ^scope_type and k.revoked == ^false
      )

    query = where_org_id(query, org_id)

    case Arca.Repo.update_all(query, set: [revoked: true, updated_at: now]) do
      {0, _} -> {:error, :not_found}
      {_, _} -> :ok
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[ApiKeyStorage] Database error in revoke_key: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Rotate a key: update key_hash, key_prefix, and rotated_at.
  """
  @spec rotate_key(String.t(), String.t(), String.t() | nil, binary(), String.t()) ::
          :ok | {:error, :not_found}
  def rotate_key(name, scope_type, org_id, new_key_hash, new_key_prefix) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    query =
      from(k in "api_keys",
        where: k.name == ^name and k.scope_type == ^scope_type and k.revoked == ^false
      )

    query = where_org_id(query, org_id)

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
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[ApiKeyStorage] Database error in rotate_key: #{Exception.message(e)}")
      {:error, :database_error}
  end

  # ============================================================================
  # Private
  # ============================================================================

  # SQLite returns booleans as strings in schemaless queries; normalize to Elixir booleans.
  defp normalize_row(row) do
    %{row | revoked: normalize_bool(row.revoked)}
  end

  defp normalize_bool(true), do: true
  defp normalize_bool(false), do: false
  defp normalize_bool("true"), do: true
  defp normalize_bool("false"), do: false
  defp normalize_bool(1), do: true
  defp normalize_bool(0), do: false
  defp normalize_bool(other), do: other
end
