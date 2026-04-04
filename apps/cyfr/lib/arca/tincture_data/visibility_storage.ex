defmodule Arca.TinctureData.VisibilityStorage do
  @moduledoc """
  SQLite storage for tincture visibility settings.

  Provides the database layer for tincture public/private state,
  scoped by tenant (org_id + project_id). Reads are cached via `Arca.Cache`.
  """

  require Logger
  require Arca.Repo.Errors
  import Ecto.Query
  import Arca.QueryHelpers, only: [where_tenant: 2]

  alias Sanctum.Context

  @doc """
  Get visibility for an authenticated context.
  """
  @spec get(Context.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :database_error}
  def get(%Context{} = ctx, publisher, name)
      when is_binary(publisher) and is_binary(name) do
    cache_key = cache_key(ctx, publisher, name)

    case Arca.Cache.get(cache_key) do
      {:ok, cached} -> {:ok, cached}
      :miss -> get_from_db(ctx, publisher, name)
    end
  end

  @doc """
  Get visibility for a public (possibly unauthenticated) context.

  Accepts any `%Sanctum.Context{}` — authenticated or not — and scopes
  by org_id/project_id.
  """
  @spec get_visibility(Context.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :database_error}
  def get_visibility(%Context{} = ctx, publisher, name)
      when is_binary(publisher) and is_binary(name) do
    org_id = Arca.QueryHelpers.normalize_org_id(ctx.org_id)
    project_id = ctx.project_id || "default"
    cache_key = {:tincture_visibility, org_id, project_id, publisher, name}

    case Arca.Cache.get(cache_key) do
      {:ok, cached} -> {:ok, cached}
      :miss -> get_visibility_from_db(org_id, project_id, publisher, name, cache_key)
    end
  end

  @spec put(Context.t(), String.t(), String.t(), boolean()) :: :ok | {:error, term()}
  def put(%Context{} = ctx, publisher, name, is_public)
      when is_binary(publisher) and is_binary(name) and is_boolean(is_public) do
    org_id = Arca.QueryHelpers.normalize_org_id(ctx.org_id)
    project_id = ctx.project_id || "default"
    now = DateTime.utc_now()
    id = generate_id(org_id, publisher, name)

    attrs = %{
      id: id,
      publisher: publisher,
      name: name,
      is_public: is_public,
      org_id: org_id,
      project_id: project_id,
      inserted_at: DateTime.to_iso8601(now),
      updated_at: DateTime.to_iso8601(now)
    }

    case Arca.Repo.insert_all(
           "tincture_visibility",
           [attrs],
           on_conflict: {:replace, [:is_public, :updated_at]},
           conflict_target: [:publisher, :name, :org_id, :project_id]
         ) do
      {_, _} ->
        invalidate_cache(ctx, publisher, name)
        :ok

      error ->
        {:error, error}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[VisibilityStorage] put error for #{publisher}/#{name}: #{Exception.message(e)}"
      )

      {:error, :database_error}
  end

  @spec delete(Context.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete(%Context{} = ctx, publisher, name) do
    query =
      from(v in "tincture_visibility",
        where: v.publisher == ^publisher and v.name == ^name
      )
      |> where_tenant(ctx)

    case Arca.Repo.delete_all(query) do
      {_, _} ->
        invalidate_cache(ctx, publisher, name)
        :ok

      error ->
        {:error, error}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[VisibilityStorage] delete error: #{Exception.message(e)}"
      )

      {:error, :database_error}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp get_from_db(ctx, publisher, name) do
    query =
      from(v in "tincture_visibility",
        where: v.publisher == ^publisher and v.name == ^name,
        limit: 1,
        select: %{
          publisher: v.publisher,
          name: v.name,
          is_public: v.is_public,
          org_id: v.org_id,
          project_id: v.project_id
        }
      )
      |> where_tenant(ctx)

    case Arca.Repo.one(query) do
      nil ->
        {:error, :not_found}

      row ->
        normalized = normalize_is_public(row)
        Arca.Cache.put(cache_key(ctx, publisher, name), normalized)
        {:ok, normalized}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[VisibilityStorage] get error for #{publisher}/#{name}: #{Exception.message(e)}"
      )

      {:error, :database_error}
  end

  defp get_visibility_from_db(org_id, project_id, publisher, name, cache_key) do
    query =
      from(v in "tincture_visibility",
        where:
          v.publisher == ^publisher and
            v.name == ^name and
            v.org_id == ^org_id and
            v.project_id == ^project_id,
        limit: 1,
        select: %{
          publisher: v.publisher,
          name: v.name,
          is_public: v.is_public,
          org_id: v.org_id,
          project_id: v.project_id
        }
      )

    case Arca.Repo.one(query) do
      nil ->
        {:error, :not_found}

      row ->
        normalized = normalize_is_public(row)
        Arca.Cache.put(cache_key, normalized)
        {:ok, normalized}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[VisibilityStorage] get_visibility error for #{publisher}/#{name}: #{Exception.message(e)}"
      )

      {:error, :database_error}
  end

  defp cache_key(ctx, publisher, name) do
    {:tincture_visibility,
     Arca.QueryHelpers.normalize_org_id(ctx.org_id), ctx.project_id || "default",
     publisher, name}
  end

  # Schemaless Ecto queries on SQLite return 0/1 for booleans, not true/false.
  # Normalize at the storage boundary so all callers see native booleans.
  defp normalize_is_public(%{is_public: val} = row) do
    %{row | is_public: val in [true, 1, "true"]}
  end

  defp invalidate_cache(ctx, publisher, name) do
    Arca.Cache.invalidate(cache_key(ctx, publisher, name))
  end

  defp generate_id(org_id, publisher, name) do
    hash =
      :crypto.hash(:sha256, "#{org_id}:#{publisher}:#{name}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "tv_#{hash}"
  end
end
