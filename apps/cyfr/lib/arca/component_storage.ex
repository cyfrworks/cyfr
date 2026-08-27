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
    # `limit: 1` over a filter that may match two rows (the same
    # name:version can exist as two component_types) — the order_by keeps
    # the pick deterministic on every adapter.
    query =
      from(c in Component,
        where: c.name == ^name and c.version == ^version,
        order_by: [desc: c.inserted_at, asc: c.id],
        limit: 1
      )
      |> where_tenant(ctx)

    query = if publisher, do: from(c in query, where: c.publisher == ^publisher), else: query

    query =
      if component_type,
        do: from(c in query, where: c.component_type == ^component_type),
        else: query

    rescuing_db("get_component", fn ->
      case Arca.Repo.one(query) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
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

    rescuing_db("get_by_digest", fn ->
      case Arca.Repo.one(query) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
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

    rescuing_db("put_component", fn -> do_put_component(attrs) end)
  end

  defp do_put_component(attrs) do
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
      conflict_target: [:athanor_id, :publisher, :name, :version, :component_type]
    )
    |> case do
      {1, _} -> {:ok, attrs}
      {0, _} -> {:ok, attrs}
      error -> {:error, error}
    end
  end

  @doc """
  Insert a new component, failing if it already exists.

  Uses `ON CONFLICT DO NOTHING` to atomically detect duplicates.
  Returns `{:ok, attrs}` on success, `{:error, :already_exists}` if the
  athanor/publisher/name/version/type combination already exists.
  """
  def insert_component(%Context{} = ctx, attrs) when is_map(attrs) do
    attrs = ensure_tenant_fields(ctx, attrs)

    rescuing_db("insert_component", fn ->
      case Arca.Repo.insert_all(Component, [attrs], on_conflict: :nothing) do
        {1, _} -> {:ok, attrs}
        {0, _} -> {:error, :already_exists}
        error -> {:error, error}
      end
    end)
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

    rescuing_db("delete_component", fn ->
      case Arca.Repo.delete_all(query) do
        {_count, _} -> :ok
        error -> {:error, error}
      end
    end)
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
  - `:limit` - Max results (default 100); `:none` returns every row —
    callers that feed completeness-sensitive answers (consent bootstrap,
    provenance maps, prune) must use it, a page here silently truncates
  """
  def list_components(%Context{} = ctx, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    # Stable baseline ordering so row order (and thus limit truncation) is
    # identical on every adapter. Semver-aware "latest" cannot be expressed
    # portably in SQL — callers that need it sort in Elixir
    # (Compendium.Registry.latest_of/1); this order_by only removes
    # adapter-defined nondeterminism.
    query =
      from(c in Component,
        order_by: [desc: c.inserted_at, asc: c.name, asc: c.version, asc: c.id]
      )
      |> where_tenant(ctx)

    query =
      if limit == :none do
        query
      else
        from(c in query, limit: ^limit)
      end

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

    rescuing_db("list_components", fn -> {:ok, Arca.Repo.all(query)} end)
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

  # The row's athanor is the context's; a caller cannot write into another.
  defp ensure_tenant_fields(%Context{athanor_id: athanor_id}, attrs)
       when is_binary(athanor_id) and athanor_id != "" do
    Map.put(attrs, :athanor_id, athanor_id)
  end

  defp ensure_tenant_fields(%Context{} = ctx, _attrs) do
    # Host programmer error — fail loud with a message, the same shape as
    # `Arca.Storage.tenant_segments/1`, not a bare FunctionClauseError.
    raise ArgumentError,
          "Arca.ComponentStorage: a resolved athanor_id is required to write component rows " <>
            "(user_id=#{inspect(ctx.user_id)} scope=#{inspect(ctx.scope)} " <>
            "auth_method=#{inspect(ctx.auth_method)})"
  end

  # One rescue for the module's typed-refusal contract: DB errors log with
  # the operation's name and answer `{:error, :database_error}`
  # (`has_remaining_versions?/3` keeps its own fail-safe rescue — its
  # fallback is `true`, not an error tuple).
  defp rescuing_db(op, fun) do
    fun.()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[ComponentStorage] Database error in #{op}: #{Exception.message(e)}")
      {:error, :database_error}
  end
end
