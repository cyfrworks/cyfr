defmodule Arca.ComponentStorage do
  @moduledoc """
  SQLite storage operations for component registry metadata.

  Provides CRUD operations for the `components` table using schemaless
  Ecto queries, following the same pattern as `Arca.PolicyStorage`.
  """

  import Ecto.Query

  @doc """
  Get a component by name and version, with optional publisher filter.

  Returns `{:ok, row}` or `{:error, :not_found}`.
  """
  @spec get_component(String.t(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, :not_found}
  def get_component(name, version, publisher \\ nil) when is_binary(name) and is_binary(version) do
    query = from(c in "components",
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
        publisher: c.publisher,
        publisher_id: c.publisher_id,
        org_id: c.org_id,
        source: c.source,
        inserted_at: c.inserted_at,
        updated_at: c.updated_at
      }
    )

    query = if publisher, do: from(c in query, where: c.publisher == ^publisher), else: query

    case Arca.Repo.one(query) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  rescue
    Ecto.QueryError -> {:error, :not_found}
    DBConnection.ConnectionError -> {:error, :not_found}
  end

  @doc """
  Save or update a component.

  Uses SQLite ON CONFLICT for upsert behavior on name+version.
  """
  @spec put_component(map()) :: {:ok, map()} | {:error, term()}
  def put_component(attrs) when is_map(attrs) do
    Arca.Repo.insert_all(
      "components",
      [attrs],
      on_conflict: {:replace, [
        :component_type,
        :description,
        :tags,
        :category,
        :license,
        :digest,
        :size,
        :exports,
        :publisher,
        :publisher_id,
        :source,
        :updated_at
      ]},
      conflict_target: [:id]
    )
    |> case do
      {1, _} -> {:ok, attrs}
      {0, _} -> {:ok, attrs}
      error -> {:error, error}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Delete a component by name and version, with optional publisher filter.
  """
  @spec delete_component(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def delete_component(name, version, publisher \\ nil) when is_binary(name) and is_binary(version) do
    query = from(c in "components", where: c.name == ^name and c.version == ^version)
    query = if publisher, do: from(c in query, where: c.publisher == ^publisher), else: query

    case Arca.Repo.delete_all(query) do
      {_count, _} -> :ok
      error -> {:error, error}
    end
  rescue
    e -> {:error, Exception.message(e)}
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
  @spec list_components(keyword()) :: [map()]
  def list_components(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    query = from(c in "components",
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
        source: c.source,
        inserted_at: c.inserted_at,
        updated_at: c.updated_at
      },
      limit: ^limit
    )

    query = if name = Keyword.get(opts, :name) do
      from(c in query, where: c.name == ^name)
    else
      query
    end

    query = if type = Keyword.get(opts, :component_type) do
      from(c in query, where: c.component_type == ^type)
    else
      query
    end

    query = if category = Keyword.get(opts, :category) do
      from(c in query, where: c.category == ^category)
    else
      query
    end

    query = if source = Keyword.get(opts, :source) do
      from(c in query, where: c.source == ^source)
    else
      query
    end

    query = if publisher = Keyword.get(opts, :publisher) do
      from(c in query, where: c.publisher == ^publisher)
    else
      query
    end

    query = if search = Keyword.get(opts, :query) do
      pattern = "%#{search}%"
      from(c in query, where: like(c.name, ^pattern) or like(c.description, ^pattern))
    else
      query
    end

    Arca.Repo.all(query)
  rescue
    _ -> []
  end

  @doc """
  Search components by text query.
  """
  @spec search_components(String.t(), keyword()) :: [map()]
  def search_components(query_text, opts \\ []) do
    list_components(Keyword.put(opts, :query, query_text))
  end

  @doc """
  Delete components by source.

  Used by the AutoIndexer to prune stale filesystem-registered entries.
  """
  @spec delete_by_source(String.t()) :: {non_neg_integer(), nil}
  def delete_by_source(source) when is_binary(source) do
    query = from(c in "components", where: c.source == ^source)
    Arca.Repo.delete_all(query)
  rescue
    _ -> {0, nil}
  end

  @doc """
  Check if a component exists by name and version, with optional publisher filter.
  """
  @spec exists?(String.t(), String.t(), String.t() | nil) :: boolean()
  def exists?(name, version, publisher \\ nil) do
    case get_component(name, version, publisher) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end
end
