defmodule SanctumArx.Projects do
  @moduledoc """
  Context module for project CRUD operations.

  All operations are gated on the Arx edition.
  """

  import Ecto.Query
  require Logger

  alias SanctumArx.Project

  def create(org_id, attrs) do
    with :ok <- require_arx() do
      now = DateTime.utc_now()

      attrs =
        attrs
        |> Map.put(:org_id, org_id)
        |> Map.put_new(:id, generate_id())
        |> Map.put_new(:created_at, now)
        |> Map.put_new(:updated_at, now)

      %Project{}
      |> Project.changeset(attrs)
      |> Arca.Repo.insert()
    end
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.error("SanctumArx.Projects: create failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def get(id) do
    with :ok <- require_arx() do
      case Arca.Repo.get(Project, id) do
        nil -> {:error, :not_found}
        project -> {:ok, project}
      end
    end
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.error("SanctumArx.Projects: get failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def get_by_slug(org_id, slug) do
    with :ok <- require_arx() do
      case Arca.Repo.get_by(Project, org_id: org_id, slug: slug) do
        nil -> {:error, :not_found}
        project -> {:ok, project}
      end
    end
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.error("SanctumArx.Projects: get_by_slug failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def update(%Project{} = project, attrs) do
    with :ok <- require_arx() do
      attrs = Map.put(attrs, :updated_at, DateTime.utc_now())

      project
      |> Project.changeset(attrs)
      |> Arca.Repo.update()
    end
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.error("SanctumArx.Projects: update failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def delete(%Project{} = project) do
    with :ok <- require_arx() do
      Arca.Repo.delete(project)
    end
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.error("SanctumArx.Projects: delete failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def list_by_org(org_id, opts \\ []) do
    with :ok <- require_arx() do
      limit = Keyword.get(opts, :limit, 50)

      from(p in Project,
        where: p.org_id == ^org_id,
        order_by: [desc: p.created_at],
        limit: ^limit
      )
      |> Arca.Repo.all()
    end
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.error("SanctumArx.Projects: list_by_org failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  defp require_arx do
    cond do
      not SanctumArx.Edition.arx?() -> {:error, :feature_not_available}
      not SanctumArx.License.valid?() -> {:error, :license_expired}
      true -> :ok
    end
  end

  defp generate_id, do: "proj_" <> Ecto.UUID.generate()
end
