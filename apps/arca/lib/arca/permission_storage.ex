defmodule Arca.PermissionStorage do
  @moduledoc """
  SQLite storage operations for permissions.

  This module provides the database layer for permission storage.
  It's called by `Sanctum.Permission` which handles JSON encoding/decoding.

  Permissions are stored as JSON arrays of permission strings.
  Subjects and scope metadata are stored as plaintext for queryability.
  """

  import Ecto.Query

  @doc """
  Get permissions for a subject.

  Returns `{:ok, permissions_json}` or `{:error, :not_found}`.
  """
  @spec get_permissions(String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :not_found}
  def get_permissions(subject, scope_type, org_id) do
    cache_key = {:permission, {subject, scope_type, org_id}}

    case Arca.Cache.get(cache_key) do
      {:ok, cached} -> {:ok, cached}
      :miss -> get_permissions_from_db(subject, scope_type, org_id)
    end
  end

  defp get_permissions_from_db(subject, scope_type, org_id) do
    query =
      from(p in "permissions",
        where: p.subject == ^subject and p.scope_type == ^scope_type,
        limit: 1,
        select: p.permissions
      )

    query = where_org_id(query, org_id)

    case Arca.Repo.one(query) do
      nil ->
        {:error, :not_found}

      permissions_json ->
        Arca.Cache.put({:permission, {subject, scope_type, org_id}}, permissions_json)
        {:ok, permissions_json}
    end
  rescue
    _ -> {:error, :not_found}
  end

  @doc """
  Set permissions for a subject (upsert).
  """
  @spec set_permissions(String.t(), String.t(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def set_permissions(subject, permissions_json, scope_type, org_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      id: Ecto.UUID.generate(),
      subject: subject,
      permissions: permissions_json,
      scope_type: scope_type,
      org_id: normalize_org_id(org_id),
      inserted_at: now,
      updated_at: now
    }

    Arca.Repo.insert_all(
      "permissions",
      [attrs],
      on_conflict: {:replace, [:permissions, :updated_at]},
      conflict_target: [:subject, :scope_type, :org_id]
    )

    Arca.Cache.invalidate({:permission, {subject, scope_type, org_id}})
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  List all subjects with their permissions for a given scope_type and org_id.
  """
  @spec list_permissions(String.t(), String.t() | nil) :: {:ok, [map()]}
  def list_permissions(scope_type, org_id) do
    query =
      from(p in "permissions",
        where: p.scope_type == ^scope_type,
        select: %{subject: p.subject, permissions: p.permissions},
        order_by: p.subject
      )

    query = where_org_id(query, org_id)

    {:ok, Arca.Repo.all(query)}
  rescue
    _ -> {:ok, []}
  end

  @doc """
  Delete permissions for a subject.
  """
  @spec delete_permissions(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def delete_permissions(subject, scope_type, org_id) do
    query =
      from(p in "permissions",
        where: p.subject == ^subject and p.scope_type == ^scope_type
      )

    query = where_org_id(query, org_id)

    Arca.Repo.delete_all(query)
    Arca.Cache.invalidate({:permission, {subject, scope_type, org_id}})
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp normalize_org_id(nil), do: ""
  defp normalize_org_id(org_id), do: org_id

  defp where_org_id(query, nil) do
    from(q in query, where: q.org_id == "")
  end

  defp where_org_id(query, org_id) do
    from(q in query, where: q.org_id == ^org_id)
  end
end
