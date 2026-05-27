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

  API keys are org-scoped by design. All queries filter by `org_id` via
  `where_org_id/2` to enforce tenant isolation in tenant-scoped
  deployments. The key hash
  serves as the authentication credential; `org_id` is derived from the
  stored key record, not from the request.
  """

  require Logger
  require Arca.Repo.Errors
  import Ecto.Query

  import Arca.QueryHelpers,
    only: [
      normalize_org_id: 1,
      normalize_project_id: 1,
      where_org_id: 3,
      where_project_id: 2
    ]

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
    :scope_type,
    :org_id,
    :project_id,
    :inserted_at,
    :updated_at
  ]

  @doc """
  Insert a new API key.

  `attrs.project_id` is normalized to `"default"` when nil/empty — SQLite's
  unique index treats NULL as distinct, so we use a fixed sentinel to ensure
  `(name, scope_type, org_id, project_id)` uniqueness detects collisions.
  """
  @spec create_key(map()) :: :ok | {:error, term()}
  def create_key(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    org = normalize_org_id(attrs[:org_id])
    project = normalize_project_id(attrs[:project_id])

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
      org_id: org,
      project_id: project,
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
  Get a key by name regardless of revoked status.
  Used to distinguish "name taken by active key" vs "name taken by revoked key".
  """
  @spec get_key_including_revoked(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, ApiKey.t()} | {:error, :not_found}
  def get_key_including_revoked(name, scope_type, org_id, project_id \\ nil) do
    project = normalize_project_id(project_id)

    query =
      from(k in ApiKey,
        where: k.name == ^name and k.scope_type == ^scope_type,
        limit: 1,
        select: [:name, :revoked]
      )

    query = query |> where_org_id(org_id, scope_type) |> where_project_id(project)

    case Arca.Repo.one(query) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[ApiKeyStorage] Database error in get_key_including_revoked: #{Exception.message(e)}"
      )

      {:error, :database_error}
  end

  @doc """
  Get a key by name, scope_type, org_id, and project_id. Excludes revoked keys.

  Returns `{:ok, row}` or `{:error, :not_found}`.
  """
  @spec get_key(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, ApiKey.t()} | {:error, :not_found}
  def get_key(name, scope_type, org_id, project_id \\ nil) do
    project = normalize_project_id(project_id)

    query =
      from(k in ApiKey,
        where: k.name == ^name and k.scope_type == ^scope_type and k.revoked == ^false,
        limit: 1,
        select: ^@returned_fields
      )

    query = query |> where_org_id(org_id, scope_type) |> where_project_id(project)

    case Arca.Repo.one(query) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[ApiKeyStorage] Database error in get_key: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Get a key by its hash. Used for validate() lookups.

  Returns `{:ok, row}` or `{:error, :not_found}`.

  API keys are project credentials: `org_id`/`project_id` are read back from
  the returned row and the tenant binding is enforced on the resulting
  `Sanctum.Context` (`require_tenant!`), NOT at lookup time. The key hash is a
  192-bit globally-unique credential, so this single untenanted lookup is the
  correct and authoritative path regardless of how the deployment is configured.
  """
  @spec get_key_by_hash(binary()) :: {:ok, ApiKey.t()} | {:error, :not_found}
  def get_key_by_hash(key_hash) do
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
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[ApiKeyStorage] Database error in get_key_by_hash: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  List all non-revoked keys for a given scope_type, org_id, and project_id,
  sorted by inserted_at.
  """
  @spec list_keys(String.t(), String.t() | nil, String.t() | nil) :: {:ok, [ApiKey.t()]}
  def list_keys(scope_type, org_id, project_id \\ nil) do
    project = normalize_project_id(project_id)

    query =
      from(k in ApiKey,
        where: k.scope_type == ^scope_type and k.revoked == ^false,
        order_by: [asc: k.inserted_at],
        select: ^@returned_fields
      )

    query = query |> where_org_id(org_id, scope_type) |> where_project_id(project)

    {:ok, Arca.Repo.all(query)}
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[ApiKeyStorage] Database error in list_keys: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Revoke a key by name, scope_type, org_id, and project_id.
  """
  @spec revoke_key(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          :ok | {:error, :not_found}
  def revoke_key(name, scope_type, org_id, project_id \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    project = normalize_project_id(project_id)

    query =
      from(k in ApiKey,
        where: k.name == ^name and k.scope_type == ^scope_type and k.revoked == ^false
      )

    query = query |> where_org_id(org_id, scope_type) |> where_project_id(project)

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

  Pass `project_id` explicitly in multi-project contexts; `nil` normalizes to
  the `"default"` project.
  """
  @spec rotate_key(
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          binary(),
          String.t()
        ) :: :ok | {:error, :not_found}
  def rotate_key(name, scope_type, org_id, project_id, new_key_hash, new_key_prefix) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    project = normalize_project_id(project_id)

    query =
      from(k in ApiKey,
        where: k.name == ^name and k.scope_type == ^scope_type and k.revoked == ^false
      )

    query = query |> where_org_id(org_id, scope_type) |> where_project_id(project)

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
end
