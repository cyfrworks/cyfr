defmodule Arca.DependencyStorage do
  @moduledoc """
  SQLite storage operations for component dependency metadata.

  Provides CRUD operations for the `component_dependencies` table using
  schemaless Ecto queries, following the same pattern as `Arca.ComponentStorage`.
  """

  require Logger
  import Ecto.Query

  @table "component_dependencies"

  @doc """
  Store dependencies for a component, replacing any existing entries.

  Accepts a component_id and a list of dependency maps, each containing:
  - `dependency_ref` (string) - canonical ref like "catalyst:local.claude:0.1.0"
  - `dep_type` (string) - component type
  - `dep_namespace` (string) - publisher namespace
  - `dep_name` (string) - component name
  - `dep_version` (string) - exact version
  - `optional` (integer, 0 or 1)
  - `reason` (string, optional)
  """
  @spec put_dependencies(String.t(), [map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def put_dependencies(component_id, deps) when is_binary(component_id) and is_list(deps) do
    # Delete existing deps for this component first
    delete_dependencies(component_id)

    now = DateTime.utc_now()

    rows =
      Enum.map(deps, fn dep ->
        %{
          id: generate_id(),
          component_id: component_id,
          dependency_ref: dep[:dependency_ref] || dep["dependency_ref"],
          dep_type: dep[:dep_type] || dep["dep_type"],
          dep_namespace: dep[:dep_namespace] || dep["dep_namespace"],
          dep_name: dep[:dep_name] || dep["dep_name"],
          dep_version: dep[:dep_version] || dep["dep_version"],
          optional: dep[:optional] || dep["optional"] || 0,
          reason: dep[:reason] || dep["reason"],
          inserted_at: now,
          updated_at: now
        }
      end)

    if rows == [] do
      {:ok, 0}
    else
      case Arca.Repo.insert_all(@table, rows) do
        {count, _} -> {:ok, count}
        error -> {:error, error}
      end
    end
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.error("[DependencyStorage] Database error in put_dependencies: #{Exception.message(e)}")
      {:error, :database_error}
    e ->
      Logger.error("[DependencyStorage] Unexpected error in put_dependencies: #{Exception.message(e)}")
      {:error, :unexpected_error}
  end

  @doc """
  Get all dependencies for a component by its ID.

  Returns `{:ok, [dep]}` or `{:error, reason}`.
  """
  @spec get_dependencies(String.t()) :: {:ok, [map()]} | {:error, term()}
  def get_dependencies(component_id) when is_binary(component_id) do
    query =
      from(d in @table,
        where: d.component_id == ^component_id,
        select: %{
          id: d.id,
          component_id: d.component_id,
          dependency_ref: d.dependency_ref,
          dep_type: d.dep_type,
          dep_namespace: d.dep_namespace,
          dep_name: d.dep_name,
          dep_version: d.dep_version,
          optional: d.optional,
          reason: d.reason,
          inserted_at: d.inserted_at,
          updated_at: d.updated_at
        }
      )

    {:ok, Arca.Repo.all(query)}
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.error("[DependencyStorage] Database error in get_dependencies: #{Exception.message(e)}")
      {:error, :database_error}
    e ->
      Logger.error("[DependencyStorage] Unexpected error in get_dependencies: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Get reverse dependencies — components that depend on the given name and version.

  Returns `{:ok, [dep]}` with entries where `dep_name` and `dep_version` match.
  """
  @spec get_reverse_dependencies(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def get_reverse_dependencies(name, version) when is_binary(name) and is_binary(version) do
    query =
      from(d in @table,
        where: d.dep_name == ^name and d.dep_version == ^version,
        select: %{
          id: d.id,
          component_id: d.component_id,
          dependency_ref: d.dependency_ref,
          dep_type: d.dep_type,
          dep_namespace: d.dep_namespace,
          dep_name: d.dep_name,
          dep_version: d.dep_version,
          optional: d.optional,
          reason: d.reason,
          inserted_at: d.inserted_at,
          updated_at: d.updated_at
        }
      )

    {:ok, Arca.Repo.all(query)}
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.error("[DependencyStorage] Database error in get_reverse_dependencies: #{Exception.message(e)}")
      {:error, :database_error}
    e ->
      Logger.error("[DependencyStorage] Unexpected error in get_reverse_dependencies: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Delete all dependencies for a component by its ID.
  """
  @spec delete_dependencies(String.t()) :: :ok | {:error, term()}
  def delete_dependencies(component_id) when is_binary(component_id) do
    query = from(d in @table, where: d.component_id == ^component_id)

    case Arca.Repo.delete_all(query) do
      {_count, _} -> :ok
      error -> {:error, error}
    end
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.error("[DependencyStorage] Database error in delete_dependencies: #{Exception.message(e)}")
      {:error, :database_error}
    e ->
      Logger.error("[DependencyStorage] Unexpected error in delete_dependencies: #{Exception.message(e)}")
      {:error, :unexpected_error}
  end

  defp generate_id do
    hash =
      :crypto.strong_rand_bytes(16)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "dep_#{hash}"
  end
end
