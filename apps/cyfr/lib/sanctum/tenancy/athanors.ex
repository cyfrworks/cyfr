# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.Athanors do
  @moduledoc """
  Athanor rows: create, find, rename, archive.

  An athanor is the unit everything is owned by — a person's or a group's.
  Rows are created here (a person's on first authorized sign-in, a group's
  when a member creates it, Home once per server) and archived, never
  deleted. Seeding an athanor with components and consents is the caller's
  job (`Compendium.AthanorSeeder`), not this module's: a row is a name,
  provisioning is what fills it.
  """

  import Ecto.Query, only: [from: 2]
  require Logger
  require Arca.Repo.Errors

  alias Arca.Schemas.Athanor

  @doc """
  Insert an athanor. `attrs` must carry `:kind`, `:name`, `:slug` and
  `:created_by`; a person athanor also `:owner_user_id`. `:id` defaults to a
  fresh `ath_` id.
  """
  @spec create(map()) :: {:ok, Athanor.t()} | {:error, term()}
  def create(attrs) do
    now = DateTime.utc_now()

    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:id, generate_id())
      |> Map.put_new(:created_at, now)
      |> Map.put_new(:updated_at, now)

    %Athanor{}
    |> Athanor.changeset(attrs)
    |> Arca.Repo.insert()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Athanors: create failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  @spec get(String.t()) :: {:ok, Athanor.t()} | {:error, :not_found | :database_error}
  def get(id) when is_binary(id) do
    case Arca.Repo.get(Athanor, id) do
      nil -> {:error, :not_found}
      athanor -> {:ok, athanor}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Athanors: get failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  @doc "Find an athanor by kind and slug."
  @spec get_by_slug(String.t(), String.t()) ::
          {:ok, Athanor.t()} | {:error, :not_found | :database_error}
  def get_by_slug(kind, slug) when is_binary(kind) and is_binary(slug) do
    case Arca.Repo.get_by(Athanor, kind: kind, slug: slug) do
      nil -> {:error, :not_found}
      athanor -> {:ok, athanor}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Athanors: get_by_slug failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  @doc """
  The server's Home athanor — the seeded group every server has. Found by
  its flag, never by a fixed id.
  """
  @spec home() :: {:ok, Athanor.t()} | {:error, :not_found | :database_error}
  def home do
    case Arca.Repo.one(from(a in Athanor, where: a.home == true, limit: 1)) do
      nil -> {:error, :not_found}
      athanor -> {:ok, athanor}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Athanors: home failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  @doc "Like `home/0`, raising when the seed is missing — a broken install."
  @spec home!() :: Athanor.t()
  def home! do
    case home() do
      {:ok, athanor} -> athanor
      {:error, reason} -> raise "Sanctum.Tenancy.Athanors: no Home athanor (#{inspect(reason)})"
    end
  end

  @spec update(Athanor.t(), map()) :: {:ok, Athanor.t()} | {:error, term()}
  def update(%Athanor{} = athanor, attrs) do
    attrs = attrs |> Map.new() |> Map.put(:updated_at, DateTime.utc_now())

    athanor
    |> Athanor.changeset(attrs)
    |> Arca.Repo.update()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Athanors: update failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  @doc "Mark an athanor archived. Nothing is deleted; every ingress gate refuses it."
  @spec archive(Athanor.t()) :: {:ok, Athanor.t()} | {:error, term()}
  def archive(%Athanor{} = athanor) do
    update(athanor, %{status: "archived", archived_at: DateTime.utc_now()})
  end

  @spec unarchive(Athanor.t()) :: {:ok, Athanor.t()} | {:error, term()}
  def unarchive(%Athanor{} = athanor) do
    update(athanor, %{status: "active", archived_at: nil})
  end

  @doc "Record that provisioning (seed + consents) completed."
  @spec mark_provisioned(Athanor.t()) :: {:ok, Athanor.t()} | {:error, term()}
  def mark_provisioned(%Athanor{} = athanor) do
    update(athanor, %{provisioned_at: DateTime.utc_now()})
  end

  @spec list_by_ids([String.t()]) :: [Athanor.t()]
  def list_by_ids([]), do: []

  def list_by_ids(ids) when is_list(ids) do
    Arca.Repo.all(from(a in Athanor, where: a.id in ^ids, order_by: [asc: a.created_at]))
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Athanors: list_by_ids failed (#{Exception.message(e)})")
      []
  end

  @doc "Whether the athanor exists and is active."
  @spec active?(String.t() | nil) :: boolean()
  def active?(id) when is_binary(id) and id != "" do
    case get(id) do
      {:ok, %Athanor{status: "active"}} -> true
      _ -> false
    end
  end

  def active?(_), do: false

  @doc "The athanor's settings document (JSON on the row), as a map."
  @spec settings(Athanor.t()) :: map()
  def settings(%Athanor{settings: nil}), do: %{}

  def settings(%Athanor{settings: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  @doc "Merge `patch` into the athanor's settings document."
  @spec put_settings(Athanor.t(), map()) :: {:ok, Athanor.t()} | {:error, term()}
  def put_settings(%Athanor{} = athanor, patch) when is_map(patch) do
    merged = Map.merge(settings(athanor), patch)
    update(athanor, %{settings: Jason.encode!(merged)})
  end

  defp generate_id, do: "ath_" <> Ecto.UUID.generate()
end
