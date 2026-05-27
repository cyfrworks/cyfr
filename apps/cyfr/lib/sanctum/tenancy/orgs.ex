# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.Orgs do
  @moduledoc """
  Context module for organization CRUD operations.

  Used in `:platform` mode to mint and manage real orgs. In `:default`
  mode the only org is the seeded `"local"` sentinel; nothing creates
  or deletes orgs there.
  """

  import Ecto.Query
  require Logger
  require Arca.Repo.Errors

  alias Arca.Schemas.Org

  def create(attrs) do
    now = DateTime.utc_now()

    attrs =
      attrs
      |> Map.put_new(:id, generate_id())
      |> Map.put_new(:created_at, now)
      |> Map.put_new(:updated_at, now)

    %Org{}
    |> Org.changeset(attrs)
    |> Arca.Repo.insert()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Orgs: create failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def get(id) do
    case Arca.Repo.get(Org, id) do
      nil -> {:error, :not_found}
      org -> {:ok, org}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Orgs: get failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def get_by_slug(slug) do
    case Arca.Repo.get_by(Org, slug: slug) do
      nil -> {:error, :not_found}
      org -> {:ok, org}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Orgs: get_by_slug failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def update(%Org{} = org, attrs) do
    attrs = Map.put(attrs, :updated_at, DateTime.utc_now())

    org
    |> Org.changeset(attrs)
    |> Arca.Repo.update()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Orgs: update failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def delete(%Org{} = org) do
    Arca.Repo.delete(org)
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Orgs: delete failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(o in Org, order_by: [desc: o.created_at], limit: ^limit)
    |> Arca.Repo.all()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Orgs: list failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  defp generate_id, do: "org_" <> Ecto.UUID.generate()
end
