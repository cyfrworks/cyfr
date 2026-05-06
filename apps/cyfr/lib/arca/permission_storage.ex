defmodule Arca.PermissionStorage do
  @moduledoc """
  SQLite/Postgres storage operations for permissions.

  Backs `Sanctum.Permission` (which handles JSON encoding/decoding).

  Permissions are stored as JSON arrays of permission strings, scoped by
  the `(org_id, project_id)` tuple. The Core single-user mode uses the
  `""` org sentinel and `"default"` project; Arx multi-project mode uses
  the real org and project ids — so a grant in project A does not leak
  into project B within the same org.

  Subjects and scope metadata are stored as plaintext for queryability.
  """

  require Logger
  require Arca.Repo.Errors
  import Ecto.Query

  import Arca.QueryHelpers,
    only: [normalize_org_id: 1, where_org_id: 2, where_project_id: 2]

  @default_project "default"

  @doc """
  Get permissions for a subject within the (org, project) tenant.

  Returns `{:ok, permissions_json}` or `{:error, :not_found}`.
  """
  @spec get_permissions(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | {:error, :not_found | :database_error}
  def get_permissions(subject, scope_type, org_id, project_id \\ nil) do
    project_id = normalize_project(project_id)
    cache_key = cache_key(subject, scope_type, org_id, project_id)

    case Arca.Cache.get(cache_key) do
      {:ok, cached} -> {:ok, cached}
      :miss -> get_permissions_from_db(subject, scope_type, org_id, project_id)
    end
  end

  defp get_permissions_from_db(subject, scope_type, org_id, project_id) do
    query =
      from(p in "permissions",
        where: p.subject == ^subject and p.scope_type == ^scope_type,
        limit: 1,
        select: p.permissions
      )
      |> where_org_id(org_id)
      |> where_project_id(project_id)

    case Arca.Repo.one(query) do
      nil ->
        {:error, :not_found}

      permissions_json ->
        Arca.Cache.put(cache_key(subject, scope_type, org_id, project_id), permissions_json)
        {:ok, permissions_json}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[PermissionStorage] Database error in get_permissions: #{Exception.message(e)}"
      )

      {:error, :database_error}
  end

  @doc """
  Set permissions for a subject within the (org, project) tenant (upsert).
  """
  @spec set_permissions(
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil
        ) :: :ok | {:error, term()}
  def set_permissions(subject, permissions_json, scope_type, org_id, project_id \\ nil) do
    project_id = normalize_project(project_id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      id: Ecto.UUID.generate(),
      subject: subject,
      permissions: permissions_json,
      scope_type: scope_type,
      org_id: normalize_org_id(org_id),
      project_id: project_id,
      inserted_at: now,
      updated_at: now
    }

    Arca.Repo.insert_all(
      "permissions",
      [attrs],
      on_conflict: {:replace, [:permissions, :updated_at]},
      conflict_target: [:subject, :scope_type, :org_id, :project_id]
    )

    Arca.Cache.invalidate(cache_key(subject, scope_type, org_id, project_id))
    :ok
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[PermissionStorage] Database error in set_permissions: #{Exception.message(e)}"
      )

      {:error, :database_error}
  end

  @doc """
  List all subjects with their permissions for a given scope_type within the
  (org, project) tenant.
  """
  @spec list_permissions(String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, [map()]} | {:error, :database_error}
  def list_permissions(scope_type, org_id, project_id \\ nil) do
    project_id = normalize_project(project_id)

    query =
      from(p in "permissions",
        where: p.scope_type == ^scope_type,
        select: %{subject: p.subject, permissions: p.permissions},
        order_by: p.subject
      )
      |> where_org_id(org_id)
      |> where_project_id(project_id)

    {:ok, Arca.Repo.all(query)}
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[PermissionStorage] Database error in list_permissions: #{Exception.message(e)}"
      )

      {:error, :database_error}
  end

  @doc """
  Delete permissions for a subject within the (org, project) tenant.
  """
  @spec delete_permissions(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          :ok | {:error, term()}
  def delete_permissions(subject, scope_type, org_id, project_id \\ nil) do
    project_id = normalize_project(project_id)

    query =
      from(p in "permissions",
        where: p.subject == ^subject and p.scope_type == ^scope_type
      )
      |> where_org_id(org_id)
      |> where_project_id(project_id)

    Arca.Repo.delete_all(query)
    Arca.Cache.invalidate(cache_key(subject, scope_type, org_id, project_id))
    :ok
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[PermissionStorage] Database error in delete_permissions: #{Exception.message(e)}"
      )

      {:error, :database_error}
  end

  defp normalize_project(nil), do: @default_project
  defp normalize_project(""), do: @default_project
  defp normalize_project(project_id) when is_binary(project_id), do: project_id

  defp cache_key(subject, scope_type, org_id, project_id) do
    {:permission, {subject, scope_type, org_id, project_id}}
  end
end
