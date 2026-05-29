# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SecretStorage do
  @moduledoc """
  Storage operations for encrypted secrets and grants.

  This module provides the database layer for secret storage.
  It's called by `Sanctum.Secrets` which handles encryption/decryption
  via the configured `Sanctum.Cipher`.

  Values are stored as encrypted binaries. Names, scopes, and grants
  are stored as plaintext for queryability.
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

  alias Arca.Schemas.Secret
  alias Arca.Schemas.SecretGrant

  @doc """
  Get a secret's encrypted value by name, scope, org_id, and project_id.

  Returns `{:ok, encrypted_value}` or `{:error, :not_found}`.
  """
  @spec get_secret(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, binary()} | {:error, :not_found}
  def get_secret(name, scope, org_id, project_id \\ "default") do
    oid = normalize_org_id(org_id)
    pid = normalize_project_id(project_id)
    cache_key = {:secret, {name, scope, oid, pid}}

    case Arca.Cache.get(cache_key) do
      {:ok, cached} -> {:ok, cached}
      :miss -> get_secret_from_db(name, scope, oid, pid)
    end
  end

  defp get_secret_from_db(name, scope, org_id, project_id) do
    query =
      from(s in Secret,
        where: s.name == ^name and s.scope == ^scope,
        limit: 1,
        select: s.encrypted_value
      )

    query = where_org_id(query, org_id, scope)
    query = where_project_id(query, project_id)

    case Arca.Repo.one(query) do
      nil ->
        {:error, :not_found}

      encrypted_value ->
        # org_id/project_id are already normalized by the caller.
        Arca.Cache.put({:secret, {name, scope, org_id, project_id}}, encrypted_value)
        {:ok, encrypted_value}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[SecretStorage] Database error in get_secret: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Upsert a secret. Inserts or updates on `(name, scope, org_id, project_id)` conflict.
  """
  @spec put_secret(String.t(), binary(), String.t(), String.t() | nil, String.t() | nil) ::
          :ok | {:error, term()}
  def put_secret(name, encrypted_value, scope, org_id, project_id \\ "default") do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    oid = normalize_org_id(org_id)
    pid = normalize_project_id(project_id)

    attrs = %{
      id: Ecto.UUID.generate(),
      name: name,
      encrypted_value: encrypted_value,
      scope: scope,
      org_id: oid,
      project_id: pid,
      inserted_at: now,
      updated_at: now
    }

    Arca.Repo.insert_all(
      Secret,
      [attrs],
      on_conflict: {:replace, [:encrypted_value, :updated_at]},
      conflict_target: [:name, :scope, :org_id, :project_id]
    )

    Arca.Cache.invalidate({:secret, {name, scope, oid, pid}})
    :ok
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[SecretStorage] Database error in put_secret: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Delete a secret by name, scope, org_id, and project_id.
  """
  @spec delete_secret(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          :ok | {:error, term()}
  def delete_secret(name, scope, org_id, project_id \\ "default") do
    oid = normalize_org_id(org_id)
    pid = normalize_project_id(project_id)
    query = from(s in Secret, where: s.name == ^name and s.scope == ^scope)
    query = where_org_id(query, oid, scope)
    query = where_project_id(query, pid)

    Arca.Repo.delete_all(query)
    Arca.Cache.invalidate({:secret, {name, scope, oid, pid}})
    :ok
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[SecretStorage] Database error in delete_secret: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  List all secret names for a given scope, org_id, and project_id.
  """
  @spec list_secrets(String.t(), String.t() | nil, String.t() | nil) :: {:ok, [String.t()]}
  def list_secrets(scope, org_id, project_id \\ "default") do
    query =
      from(s in Secret,
        where: s.scope == ^scope,
        select: s.name,
        order_by: s.name
      )

    query = where_org_id(query, org_id, scope)
    query = where_project_id(query, project_id)

    {:ok, Arca.Repo.all(query)}
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[SecretStorage] Database error in list_secrets: #{Exception.message(e)}")
      {:error, :database_error}
  end

  # ============================================================================
  # Grants
  # ============================================================================

  @doc """
  Insert a grant. Ignores conflict (idempotent).
  """
  @spec put_grant(String.t(), String.t(), String.t(), String.t() | nil, String.t()) ::
          :ok | {:error, term()}
  def put_grant(secret_name, component_ref, scope, org_id, project_id \\ "default") do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      id: Ecto.UUID.generate(),
      secret_name: secret_name,
      component_ref: component_ref,
      scope: scope,
      org_id: normalize_org_id(org_id),
      project_id: normalize_project_id(project_id),
      inserted_at: now
    }

    Arca.Repo.insert_all(SecretGrant, [attrs],
      on_conflict: :nothing,
      conflict_target: [:secret_name, :component_ref, :org_id, :project_id]
    )

    :ok
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[SecretStorage] Database error in put_grant: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Delete a grant.
  """
  @spec delete_grant(String.t(), String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          :ok | {:error, term()}
  def delete_grant(secret_name, component_ref, scope, org_id, project_id \\ "default") do
    query =
      from(g in SecretGrant,
        where:
          g.secret_name == ^secret_name and
            g.component_ref == ^component_ref and
            g.scope == ^scope
      )

    query = where_org_id(query, org_id, scope)
    query = where_project_id(query, project_id)

    Arca.Repo.delete_all(query)
    :ok
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[SecretStorage] Database error in delete_grant: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  List component_refs granted access to a secret.
  """
  @spec list_grants(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, [String.t()]}
  def list_grants(secret_name, scope, org_id, project_id \\ "default") do
    query =
      from(g in SecretGrant,
        where: g.secret_name == ^secret_name and g.scope == ^scope,
        select: g.component_ref
      )

    query = where_org_id(query, org_id, scope)
    query = where_project_id(query, project_id)

    {:ok, Arca.Repo.all(query)}
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[SecretStorage] Database error in list_grants: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  List secret_names that a component has been granted access to.
  Used by `resolve_granted_secrets`.
  """
  @spec grants_for_component(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, [String.t()]}
  def grants_for_component(component_ref, scope, org_id, project_id \\ "default") do
    query =
      from(g in SecretGrant,
        where: g.component_ref == ^component_ref and g.scope == ^scope,
        select: g.secret_name
      )

    query = where_org_id(query, org_id, scope)
    query = where_project_id(query, project_id)

    {:ok, Arca.Repo.all(query)}
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[SecretStorage] Database error in grants_for_component: #{Exception.message(e)}"
      )

      {:error, :database_error}
  end

  @doc """
  Delete all grants for a given component_ref within the tenant scope.

  Used during component pruning/deletion to clean up orphaned grants.
  Returns `:ok` regardless of how many rows were deleted.
  """
  @spec delete_grants_for_component(Sanctum.Context.t(), String.t()) :: :ok | {:error, term()}
  def delete_grants_for_component(%Sanctum.Context{} = ctx, component_ref)
      when is_binary(component_ref) do
    org_id = normalize_org_id(ctx.org_id)
    project_id = ctx.project_id

    query =
      from(g in SecretGrant,
        where: g.component_ref == ^component_ref,
        where: g.org_id == ^org_id,
        where: g.project_id == ^project_id
      )

    Arca.Repo.delete_all(query)
    :ok
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[SecretStorage] Database error in delete_grants_for_component: #{Exception.message(e)}"
      )

      {:error, :database_error}
  end
end