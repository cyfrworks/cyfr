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

  Home (`home: true`) and person athanors are archived only through
  `Sanctum.Tenancy.Users.deny/1` (`force: true`); a group is archived by its
  members or by its last member leaving.
  """

  import Ecto.Query, only: [from: 2]
  require Logger
  require Arca.Repo.Errors

  alias Arca.Schemas.{Athanor, Membership}
  alias Sanctum.Tenancy.Caps

  @doc """
  Insert an athanor. `attrs` must carry `:kind`, `:name`, `:slug` and
  `:created_by`; a person athanor also `:owner_user_id`. `:id` defaults to a
  fresh `ath_` id. The server-wide cap on athanors applies.
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

    with :ok <- Caps.check(:max_athanors, count()) do
      %Athanor{}
      |> Athanor.changeset(attrs)
      |> Arca.Repo.insert()
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Athanors: create failed (#{Exception.message(e)})")
      {:error, :database_error}
  end

  @doc """
  Mint a group athanor for `creator_user_id`: the row, its slug (from the
  name, or `:slug`), and the creator's membership — nobody else is added.
  The per-person cap on groups applies.
  """
  @spec create_group(String.t(), String.t(), keyword()) ::
          {:ok, Athanor.t()} | {:error, term()}
  def create_group(creator_user_id, name, opts \\ [])
      when is_binary(creator_user_id) and is_binary(name) do
    name = String.trim(name)

    with :ok <- validate_name(name),
         :ok <- Caps.check(:max_groups_per_person, count_groups_created_by(creator_user_id)),
         {:ok, slug} <- resolve_slug(Keyword.get(opts, :slug), name),
         {:ok, athanor} <-
           create(%{kind: "group", name: name, slug: slug, created_by: creator_user_id}),
         {:ok, _} <-
           Sanctum.Tenancy.Members.create(%{
             user_id: creator_user_id,
             scope: "athanor",
             athanor_id: athanor.id,
             added_by: creator_user_id
           }) do
      Sanctum.Tenancy.Members.broadcast_change(creator_user_id, athanor.id, :joined)
      {:ok, athanor}
    end
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
  Resolve a route segment: `@<namespace>` names a person's athanor, a bare
  slug a group's. Only active athanors resolve.
  """
  @spec by_route_slug(String.t()) :: {:ok, Athanor.t()} | {:error, :not_found}
  def by_route_slug("@" <> namespace) when namespace != "" do
    active_only(get_by_slug("person", namespace))
  end

  def by_route_slug(slug) when is_binary(slug) and slug != "" do
    active_only(get_by_slug("group", slug))
  end

  def by_route_slug(_), do: {:error, :not_found}

  @doc "The route segment for an athanor: `@<slug>` for a person, the slug for a group."
  @spec route_slug(Athanor.t()) :: String.t()
  def route_slug(%Athanor{kind: "person", slug: slug}), do: "@" <> slug
  def route_slug(%Athanor{slug: slug}), do: slug

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

  @doc "Rename an athanor. The slug stays: it is an address."
  @spec rename(Athanor.t(), String.t()) :: {:ok, Athanor.t()} | {:error, term()}
  def rename(%Athanor{} = athanor, name) when is_binary(name) do
    name = String.trim(name)

    with :ok <- validate_name(name) do
      update(athanor, %{name: name})
    end
  end

  @doc """
  Mark an athanor archived. Nothing is deleted; every ingress gate refuses it.

  Home and person athanors refuse unless `force: true` — the arm
  `Sanctum.Tenancy.Users.deny/1` uses when it ejects a person.
  """
  @spec archive(Athanor.t(), keyword()) :: {:ok, Athanor.t()} | {:error, term()}
  def archive(%Athanor{} = athanor, opts \\ []) do
    # Re-read first: callers often hold a struct from before the last change,
    # and a changeset built on a stale status would write nothing.
    with {:ok, current} <- get(athanor.id) do
      cond do
        current.status == "archived" ->
          {:ok, current}

        current.home and not Keyword.get(opts, :force, false) ->
          {:error, :home_cannot_be_archived}

        current.kind == "person" and not Keyword.get(opts, :force, false) ->
          {:error, :person_athanor_cannot_be_archived}

        true ->
          update(current, %{status: "archived", archived_at: DateTime.utc_now()})
      end
    end
  end

  @spec unarchive(Athanor.t()) :: {:ok, Athanor.t()} | {:error, term()}
  def unarchive(%Athanor{} = athanor) do
    with {:ok, current} <- get(athanor.id) do
      update(current, %{status: "active", archived_at: nil})
    end
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

  @doc """
  The active athanors a person may work in: their own, then every group an
  active membership grants, oldest first. Uncapped — a person's memberships
  are few, and a truncated list would hide a chat.
  """
  @spec list_for_user(String.t()) :: [Athanor.t()]
  def list_for_user(user_id) when is_binary(user_id) do
    Arca.Repo.all(
      from(a in Athanor,
        join: m in Membership,
        on: m.athanor_id == a.id,
        where:
          m.user_id == ^user_id and m.scope == "athanor" and m.status == "active" and
            a.status == "active",
        distinct: true,
        order_by: [desc: a.kind == "person", asc: a.created_at]
      )
    )
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Athanors: list_for_user failed (#{Exception.message(e)})")
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

  @doc "How many athanors were created after `since`."
  @spec count_created_since(DateTime.t()) :: non_neg_integer()
  def count_created_since(%DateTime{} = since) do
    Arca.Repo.one(from(a in Athanor, where: a.created_at > ^since, select: count(a.id))) || 0
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Athanors: count_created_since failed (#{Exception.message(e)})")
      0
  end

  @doc "How many athanors this server holds."
  @spec count() :: non_neg_integer()
  def count do
    Arca.Repo.one(from(a in Athanor, select: count(a.id))) || 0
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Athanors: count failed (#{Exception.message(e)})")
      0
  end

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

  # ---- internal --------------------------------------------------------------

  defp active_only({:ok, %Athanor{status: "active"} = athanor}), do: {:ok, athanor}
  defp active_only(_), do: {:error, :not_found}

  defp validate_name(name) when byte_size(name) in 1..80, do: :ok
  defp validate_name(_), do: {:error, :invalid_name}

  # A slug given explicitly must be valid and free; one derived from the name
  # gets a numeric suffix when taken.
  defp resolve_slug(explicit, _name) when is_binary(explicit) do
    if Sanctum.Slug.valid?(explicit) and slug_free?(explicit),
      do: {:ok, explicit},
      else: {:error, :slug_taken_or_invalid}
  end

  defp resolve_slug(nil, name) do
    case Sanctum.Slug.from_name(name) do
      nil ->
        {:error, :invalid_name}

      base ->
        candidates = [base | Enum.map(2..50, &"#{String.slice(base, 0, 36)}-#{&1}")]

        case Enum.find(candidates, &slug_free?/1) do
          nil -> {:error, :slug_taken_or_invalid}
          slug -> {:ok, slug}
        end
    end
  end

  defp slug_free?(slug), do: match?({:error, :not_found}, get_by_slug("group", slug))

  defp count_groups_created_by(user_id) do
    Arca.Repo.one(
      from(a in Athanor,
        where: a.kind == "group" and a.created_by == ^user_id and a.status == "active",
        select: count(a.id)
      )
    ) || 0
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("Sanctum.Tenancy.Athanors: count_groups failed (#{Exception.message(e)})")
      0
  end

  defp generate_id, do: "ath_" <> Ecto.UUID.generate()
end
