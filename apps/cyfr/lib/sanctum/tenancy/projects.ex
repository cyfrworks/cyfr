# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.Projects do
  @moduledoc """
  Context module for project CRUD operations.

  In `:default` mode the only project is the seeded `"default"`
  under the `"local"` org. In `:platform` mode operators create
  projects per org through this module.
  """

  import Ecto.Query
  require Logger
  require Arca.Repo.Errors

  alias Sanctum.Tenancy.Project

  def create(org_id, attrs) do
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
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Projects: create failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def get(id) do
    case Arca.Repo.get(Project, id) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Projects: get failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def get_by_slug(org_id, slug) do
    case Arca.Repo.get_by(Project, org_id: org_id, slug: slug) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Projects: get_by_slug failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def update(%Project{} = project, attrs) do
    attrs = Map.put(attrs, :updated_at, DateTime.utc_now())

    project
    |> Project.changeset(attrs)
    |> Arca.Repo.update()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Projects: update failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def delete(%Project{} = project) do
    Arca.Repo.delete(project)
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Projects: delete failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def list_by_org(org_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(p in Project,
      where: p.org_id == ^org_id,
      order_by: [desc: p.created_at],
      limit: ^limit
    )
    |> Arca.Repo.all()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Projects: list_by_org failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  defp generate_id, do: "proj_" <> Ecto.UUID.generate()
end
