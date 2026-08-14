# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ComponentStorage do
  @moduledoc """
  Storage operations for component registry metadata.

  Provides CRUD operations for the `components` table via the
  `Arca.Schemas.Component` schema. Reads return `%Arca.Schemas.Component{}`
  structs; the `Compendium` layer normalizes them into its own document
  representation (which it also builds from remote-registry responses).

  All public functions take a `%Sanctum.Context{}` as the first argument
  to enforce tenant isolation via `where_tenant/3`.
  """

  require Logger
  require Arca.Repo.Errors
  import Ecto.Query
  import Arca.QueryHelpers, only: [where_tenant: 2]

  alias Arca.Schemas.Component
  alias Sanctum.Context

  @doc """
  Get a component by name and version, with optional publisher and component_type filters.

  Returns `{:ok, row}` or `{:error, :not_found}`.
  """
  def get_component(%Context{} = ctx, name, version, publisher \\ nil, component_type \\ nil)
      when is_binary(name) and is_binary(version) do
    query =
      from(c in Component, where: c.name == ^name and c.version == ^version, limit: 1)
      |> where_tenant(ctx)

    query = if publisher, do: from(c in query, where: c.publisher == ^publisher), else: query

    query =
      if component_type,
        do: from(c in query, where: c.component_type == ^component_type),
        else: query

    case Arca.Repo.one(query) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[ComponentStorage] Database error in get_component: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Get a component by its WASM digest (SHA256 hash).

  Returns `{:ok, row}` or `{:error, :not_found}`.
  This is a direct index lookup, avoiding O(n) scan of all components.
  """
  def get_by_digest(%Context{} = ctx, digest) when is_binary(digest) do
    query =
      from(c in Component, where: c.digest == ^digest, limit: 1)
      |> where_tenant(ctx)

    case Arca.Repo.one(query) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[ComponentStorage] Database error in get_by_digest: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Save or update a component.

  Uses ON CONFLICT for upsert behavior on id. Persists already-validated
  attributes — component-identity validation is the registry's responsibility
  (`Compendium.Registry`), not the storage layer's. Ensures tenant fields from
  the context.
  """
  def put_component(%Context{} = ctx, attrs) when is_map(attrs) do
    attrs = ensure_tenant_fields(ctx, attrs)

    Arca.Repo.insert_all(
      Component,
      [attrs],
      on_conflict:
        {:replace,
         [
           :description,
           :tags,
           :category,
           :license,
           :digest,
           :release_digest,
           :size,
           :exports,
           :manifest,
           :publisher_id,
           :source,
           :signature_verified,
           :signer_identity,
           :signer_issuer,
           :updated_at
         ]},
      conflict_target: [:publisher, :name, :version, :component_type, :org_id, :project_id]
    )
    |> case do
      {1, _} -> {:ok, attrs}
      {0, _} -> {:ok, attrs}
      error -> {:error, error}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[ComponentStorage] Database error in put_component: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Insert a new component, failing if it already exists.

  Uses `ON CONFLICT DO NOTHING` to atomically detect duplicates.
  Returns `{:ok, attrs}` on success, `{:error, :already_exists}` if the
  name/version/publisher/org_id/project_id combination already exists.
  """
  def insert_component(%Context{} = ctx, attrs) when is_map(attrs) do
    attrs = ensure_tenant_fields(ctx, attrs)

    case Arca.Repo.insert_all(Component, [attrs], on_conflict: :nothing) do
      {1, _} -> {:ok, attrs}
      {0, _} -> {:error, :already_exists}
      error -> {:error, error}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[ComponentStorage] Database error in insert_component: #{Exception.message(e)}"
      )

      {:error, :database_error}
  end

  @doc """
  Delete a component by name and version, with optional publisher and component_type filters.
  """
  def delete_component(%Context{} = ctx, name, version, publisher \\ nil, component_type \\ nil)
      when is_binary(name) and is_binary(version) do
    query =
      from(c in Component, where: c.name == ^name and c.version == ^version)
      |> where_tenant(ctx)

    query = if publisher, do: from(c in query, where: c.publisher == ^publisher), else: query

    query =
      if component_type,
        do: from(c in query, where: c.component_type == ^component_type),
        else: query

    case Arca.Repo.delete_all(query) do
      {_count, _} -> :ok
      error -> {:error, error}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[ComponentStorage] Database error in delete_component: #{Exception.message(e)}"
      )

      {:error, :database_error}
  end

  @doc """
  Check if any versions of a component exist for the given name, publisher, and tenant.
  Used during component removal to determine if name-level grants/policies should be cleaned up.
  """
  def has_remaining_versions?(%Context{} = ctx, name, publisher)
      when is_binary(name) and is_binary(publisher) do
    query =
      from(c in Component,
        where: c.name == ^name and c.publisher == ^publisher,
        select: c.id,
        limit: 1
      )
      |> where_tenant(ctx)

    Arca.Repo.one(query) != nil
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[ComponentStorage] Database error in has_remaining_versions?: #{Exception.message(e)}"
      )

      # Fail safe: assume versions remain, don't delete name-level entries
      true
  end

  @doc """
  List components with optional filters.

  ## Options

  - `:name` - Filter by exact name
  - `:component_type` - Filter by type (catalyst, reagent, formula)
  - `:query` - Text search in name/description
  - `:category` - Filter by category
  - `:limit` - Max results (default 100)
  """
  def list_components(%Context{} = ctx, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    # Stable baseline ordering so row order (and thus limit truncation) is
    # identical on every adapter. Semver-aware "latest" cannot be expressed
    # portably in SQL — callers that need it sort in Elixir
    # (Compendium.Registry.latest_row/4); this order_by only removes
    # adapter-defined nondeterminism.
    query =
      from(c in Component,
        order_by: [desc: c.inserted_at, asc: c.name, asc: c.version, asc: c.id],
        limit: ^limit
      )
      |> where_tenant(ctx)

    query =
      if name = Keyword.get(opts, :name) do
        from(c in query, where: c.name == ^name)
      else
        query
      end

    query =
      if type = Keyword.get(opts, :component_type) do
        from(c in query, where: c.component_type == ^type)
      else
        query
      end

    query =
      if category = Keyword.get(opts, :category) do
        from(c in query, where: c.category == ^category)
      else
        query
      end

    query =
      if source = Keyword.get(opts, :source) do
        from(c in query, where: c.source == ^source)
      else
        query
      end

    query =
      if publisher = Keyword.get(opts, :publisher) do
        from(c in query, where: c.publisher == ^publisher)
      else
        query
      end

    query =
      if search = Keyword.get(opts, :query) do
        # Case-insensitive on both adapters: SQLite LIKE folds ASCII case but
        # Postgres LIKE does not, so lower() both sides rather than rely on LIKE.
        pattern = "%#{String.downcase(search)}%"

        from(c in query,
          where:
            like(fragment("lower(?)", c.name), ^pattern) or
              like(fragment("lower(?)", c.description), ^pattern)
        )
      else
        query
      end

    {:ok, Arca.Repo.all(query)}
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[ComponentStorage] Database error in list_components: #{Exception.message(e)}"
      )

      {:error, :database_error}
  end

  @doc """
  Check if a component exists by name and version, with optional publisher and component_type filters.
  """
  def exists?(%Context{} = ctx, name, version, publisher \\ nil, component_type \\ nil) do
    case get_component(ctx, name, version, publisher, component_type) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp ensure_tenant_fields(%Context{} = ctx, attrs) do
    attrs
    |> Map.put_new(:project_id, Arca.QueryHelpers.normalize_project_id(ctx.project_id))
    |> Map.put_new(:org_id, Arca.QueryHelpers.normalize_org_id(ctx.org_id))
  end
end
