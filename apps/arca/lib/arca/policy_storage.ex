defmodule Arca.PolicyStorage do
  @moduledoc """
  SQLite storage operations for Host Policies.

  This module provides the database layer for policy storage.
  Reads are cached via `Arca.Cache` for performance.

  ## Schema

  The `policies` table stores:
  - id: Unique policy ID
  - component_ref: Component reference (unique)
  - component_type: reagent/catalyst/formula
  - allowed_domains: JSON array of domains
  - allowed_methods: JSON array of HTTP methods
  - rate_limit_requests: Integer requests per window
  - rate_limit_window_seconds: Integer window size
  - timeout: String timeout (e.g., "30s")
  - max_memory_bytes: Integer memory limit
  - max_request_size: Integer request size limit
  - max_response_size: Integer response size limit
  - inserted_at/updated_at: Timestamps
  """

  import Ecto.Query

  @doc """
  Get a policy by component reference.

  Returns `{:ok, row}` or `{:error, :not_found}`.
  """
  @spec get_policy(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_policy(component_ref) when is_binary(component_ref) do
    cache_key = {:policy, component_ref}

    case Arca.Cache.get(cache_key) do
      {:ok, cached} -> {:ok, cached}
      :miss -> get_policy_from_db(component_ref)
    end
  end

  defp get_policy_from_db(component_ref) do
    # SQLite requires explicit column selection for schemaless queries
    query = from(p in "policies",
      where: p.component_ref == ^component_ref,
      limit: 1,
      select: %{
        id: p.id,
        component_ref: p.component_ref,
        component_type: p.component_type,
        allowed_domains: p.allowed_domains,
        allowed_methods: p.allowed_methods,
        rate_limit_requests: p.rate_limit_requests,
        rate_limit_window_seconds: p.rate_limit_window_seconds,
        timeout: p.timeout,
        max_memory_bytes: p.max_memory_bytes,
        max_request_size: p.max_request_size,
        max_response_size: p.max_response_size,
        allowed_tools: p.allowed_tools,
        allowed_storage_paths: p.allowed_storage_paths,
        inserted_at: p.inserted_at,
        updated_at: p.updated_at
      }
    )

    case Arca.Repo.one(query) do
      nil ->
        {:error, :not_found}

      row ->
        Arca.Cache.put({:policy, component_ref}, row)
        {:ok, row}
    end
  rescue
    # Handle case where table doesn't exist yet (migration not run)
    Ecto.QueryError -> {:error, :not_found}
    DBConnection.ConnectionError -> {:error, :not_found}
  end

  @doc """
  Save or update a policy.

  Uses SQLite ON CONFLICT for upsert behavior.
  """
  @spec put_policy(map()) :: {:ok, map()} | {:error, term()}
  def put_policy(attrs) when is_map(attrs) do
    Arca.Repo.insert_all(
      "policies",
      [attrs],
      on_conflict: {:replace, [
        :allowed_domains,
        :allowed_methods,
        :rate_limit_requests,
        :rate_limit_window_seconds,
        :timeout,
        :max_memory_bytes,
        :max_request_size,
        :max_response_size,
        :allowed_tools,
        :allowed_storage_paths,
        :updated_at
      ]},
      conflict_target: [:component_ref]
    )
    |> case do
      {1, _} ->
        Arca.Cache.invalidate({:policy, attrs["component_ref"] || attrs[:component_ref]})
        {:ok, attrs}

      {0, _} ->
        Arca.Cache.invalidate({:policy, attrs["component_ref"] || attrs[:component_ref]})
        {:ok, attrs}

      error ->
        {:error, error}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Delete a policy by component reference.
  """
  @spec delete_policy(String.t()) :: :ok | {:error, term()}
  def delete_policy(component_ref) when is_binary(component_ref) do
    query = from(p in "policies", where: p.component_ref == ^component_ref)

    case Arca.Repo.delete_all(query) do
      {_count, _} ->
        Arca.Cache.invalidate({:policy, component_ref})
        :ok

      error ->
        {:error, error}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  List all policies.
  """
  @spec list_policies() :: [map()]
  def list_policies do
    # SQLite requires explicit column selection for schemaless queries
    query = from(p in "policies",
      select: %{
        id: p.id,
        component_ref: p.component_ref,
        component_type: p.component_type,
        allowed_domains: p.allowed_domains,
        allowed_methods: p.allowed_methods,
        rate_limit_requests: p.rate_limit_requests,
        rate_limit_window_seconds: p.rate_limit_window_seconds,
        timeout: p.timeout,
        max_memory_bytes: p.max_memory_bytes,
        max_request_size: p.max_request_size,
        max_response_size: p.max_response_size,
        allowed_tools: p.allowed_tools,
        allowed_storage_paths: p.allowed_storage_paths,
        inserted_at: p.inserted_at,
        updated_at: p.updated_at
      }
    )
    Arca.Repo.all(query)
  rescue
    _ -> []
  end
end
