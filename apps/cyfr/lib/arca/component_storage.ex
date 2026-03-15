defmodule Arca.ComponentStorage do
  @moduledoc """
  SQLite storage operations for component registry metadata.

  Provides CRUD operations for the `components` table using schemaless
  Ecto queries, following the same pattern as `Arca.PolicyStorage`.

  All public functions take a `%Sanctum.Context{}` as the first argument
  to enforce tenant isolation via `where_tenant/3`.
  """

  require Logger
  import Ecto.Query
  import Arca.QueryHelpers, only: [where_tenant: 2]

  alias Sanctum.Context

  @doc """
  Get a component by name and version, with optional publisher and component_type filters.

  Returns `{:ok, row}` or `{:error, :not_found}`.
  """
  def get_component(%Context{} = ctx, name, version, publisher \\ nil, component_type \\ nil)
      when is_binary(name) and is_binary(version) do
    query =
      from(c in "components",
        where: c.name == ^name and c.version == ^version,
        limit: 1,
        select: %{
          id: c.id,
          name: c.name,
          version: c.version,
          component_type: c.component_type,
          description: c.description,
          tags: c.tags,
          category: c.category,
          license: c.license,
          digest: c.digest,
          size: c.size,
          exports: c.exports,
          manifest: c.manifest,
          publisher: c.publisher,
          publisher_id: c.publisher_id,
          org_id: c.org_id,
          project_id: c.project_id,
          source: c.source,
          signature_verified: c.signature_verified,
          signer_identity: c.signer_identity,
          signer_issuer: c.signer_issuer,
          inserted_at: c.inserted_at,
          updated_at: c.updated_at
        }
      )
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
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
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
      from(c in "components",
        where: c.digest == ^digest,
        limit: 1,
        select: %{
          id: c.id,
          name: c.name,
          version: c.version,
          component_type: c.component_type,
          description: c.description,
          tags: c.tags,
          category: c.category,
          license: c.license,
          digest: c.digest,
          size: c.size,
          exports: c.exports,
          manifest: c.manifest,
          publisher: c.publisher,
          publisher_id: c.publisher_id,
          org_id: c.org_id,
          project_id: c.project_id,
          source: c.source,
          signature_verified: c.signature_verified,
          signer_identity: c.signer_identity,
          signer_issuer: c.signer_issuer,
          inserted_at: c.inserted_at,
          updated_at: c.updated_at
        }
      )
      |> where_tenant(ctx)

    case Arca.Repo.one(query) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.error("[ComponentStorage] Database error in get_by_digest: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Validate component attributes before storage.

  Checks that required fields (name, version, component_type, publisher) are
  present and non-empty, and that each passes its corresponding
  `Sanctum.ComponentRef` field validator.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_attrs(map()) :: :ok | {:error, term()}
  def validate_attrs(attrs) when is_map(attrs) do
    with {:ok, name} <- require_field(attrs, :name),
         {:ok, version} <- require_field(attrs, :version),
         {:ok, type} <- require_field(attrs, :component_type),
         {:ok, publisher} <- require_field(attrs, :publisher),
         :ok <- Sanctum.ComponentRef.validate_name(name),
         :ok <- Sanctum.ComponentRef.validate_version(version),
         :ok <- Sanctum.ComponentRef.validate_type(type),
         :ok <- Sanctum.ComponentRef.validate_publisher(publisher) do
      :ok
    end
  end

  defp require_field(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, to_string(key)) do
      nil -> {:error, {:missing_required, key}}
      "" -> {:error, {:missing_required, key}}
      value -> {:ok, value}
    end
  end

  @doc """
  Save or update a component.

  Uses SQLite ON CONFLICT for upsert behavior on id.
  Validates attributes before writing. Ensures project_id is set from context.
  """
  def put_component(%Context{} = ctx, attrs) when is_map(attrs) do
    attrs = ensure_tenant_fields(ctx, attrs)

    with :ok <- validate_attrs(attrs) do
      Arca.Repo.insert_all(
        "components",
        [attrs],
        on_conflict:
          {:replace,
           [
             :component_type,
             :description,
             :tags,
             :category,
             :license,
             :digest,
             :size,
             :exports,
             :manifest,
             :publisher,
             :publisher_id,
             :source,
             :signature_verified,
             :signer_identity,
             :signer_issuer,
             :updated_at
           ]},
        conflict_target: [:name, :version, :publisher, :org_id, :project_id]
      )
      |> case do
        {1, _} -> {:ok, attrs}
        {0, _} -> {:ok, attrs}
        error -> {:error, error}
      end
    end
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
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

    with :ok <- validate_attrs(attrs) do
      case Arca.Repo.insert_all("components", [attrs], on_conflict: :nothing) do
        {1, _} -> {:ok, attrs}
        {0, _} -> {:error, :already_exists}
        error -> {:error, error}
      end
    end
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.error("[ComponentStorage] Database error in insert_component: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Delete a component by name and version, with optional publisher and component_type filters.
  """
  def delete_component(%Context{} = ctx, name, version, publisher \\ nil, component_type \\ nil)
      when is_binary(name) and is_binary(version) do
    query =
      from(c in "components", where: c.name == ^name and c.version == ^version)
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
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.error(
        "[ComponentStorage] Database error in delete_component: #{Exception.message(e)}"
      )

      {:error, :database_error}
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

    query =
      from(c in "components",
        select: %{
          id: c.id,
          name: c.name,
          version: c.version,
          component_type: c.component_type,
          description: c.description,
          tags: c.tags,
          category: c.category,
          license: c.license,
          digest: c.digest,
          size: c.size,
          exports: c.exports,
          publisher: c.publisher,
          publisher_id: c.publisher_id,
          org_id: c.org_id,
          project_id: c.project_id,
          source: c.source,
          signature_verified: c.signature_verified,
          signer_identity: c.signer_identity,
          signer_issuer: c.signer_issuer,
          inserted_at: c.inserted_at,
          updated_at: c.updated_at
        },
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
        pattern = "%#{search}%"
        from(c in query, where: like(c.name, ^pattern) or like(c.description, ^pattern))
      else
        query
      end

    {:ok, Arca.Repo.all(query)}
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.error(
        "[ComponentStorage] Database error in list_components: #{Exception.message(e)}"
      )

      {:error, :storage_error}
  end

  @doc """
  Search components by text query.
  """
  def search_components(%Context{} = ctx, query_text, opts \\ []) do
    list_components(ctx, Keyword.put(opts, :query, query_text))
  end

  @doc """
  Delete components by source.

  Used by the AutoIndexer to prune stale filesystem-registered entries.
  """
  def delete_by_source(%Context{} = ctx, source) when is_binary(source) do
    query =
      from(c in "components", where: c.source == ^source)
      |> where_tenant(ctx)

    Arca.Repo.delete_all(query)
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.error(
        "[ComponentStorage] Database error in delete_by_source: #{Exception.message(e)}"
      )

      {0, nil}
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
    |> Map.put_new(:project_id, ctx.project_id || "default")
    |> Map.put_new(:org_id, Arca.QueryHelpers.normalize_org_id(ctx.org_id))
  end
end
