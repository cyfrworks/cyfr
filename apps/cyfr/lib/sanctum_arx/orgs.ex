defmodule SanctumArx.Orgs do
  @moduledoc """
  Context module for organization CRUD operations.

  All operations are gated on the Arx edition.
  """

  import Ecto.Query
  require Logger
  require Arca.Repo.Errors

  alias SanctumArx.Org

  def create(attrs) do
    with :ok <- require_arx() do
      now = DateTime.utc_now()

      attrs =
        attrs
        |> Map.put_new(:id, generate_id())
        |> Map.put_new(:created_at, now)
        |> Map.put_new(:updated_at, now)

      %Org{}
      |> Org.changeset(attrs)
      |> Arca.Repo.insert()
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("SanctumArx.Orgs: create failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def get(id) do
    with :ok <- require_arx() do
      case Arca.Repo.get(Org, id) do
        nil -> {:error, :not_found}
        org -> {:ok, org}
      end
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("SanctumArx.Orgs: get failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def get_by_slug(slug) do
    with :ok <- require_arx() do
      case Arca.Repo.get_by(Org, slug: slug) do
        nil -> {:error, :not_found}
        org -> {:ok, org}
      end
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("SanctumArx.Orgs: get_by_slug failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def update(%Org{} = org, attrs) do
    with :ok <- require_arx() do
      attrs = Map.put(attrs, :updated_at, DateTime.utc_now())

      org
      |> Org.changeset(attrs)
      |> Arca.Repo.update()
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("SanctumArx.Orgs: update failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def delete(%Org{} = org) do
    with :ok <- require_arx() do
      Arca.Repo.delete(org)
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("SanctumArx.Orgs: delete failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def list(opts \\ []) do
    with :ok <- require_arx() do
      limit = Keyword.get(opts, :limit, 50)

      from(o in Org, order_by: [desc: o.created_at], limit: ^limit)
      |> Arca.Repo.all()
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("SanctumArx.Orgs: list failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  defp require_arx do
    cond do
      not SanctumArx.Edition.arx?() -> {:error, :feature_not_available}
      not SanctumArx.License.valid?() -> {:error, :license_expired}
      true -> :ok
    end
  end

  defp generate_id, do: "org_" <> Ecto.UUID.generate()
end
