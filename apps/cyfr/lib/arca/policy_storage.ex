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
  - allowed_private_ips: JSON array of private IPs/CIDRs allowed
  - inserted_at/updated_at: Timestamps
  """

  require Logger
  require Arca.Repo.Errors
  import Ecto.Query
  import Arca.QueryHelpers, only: [where_tenant: 2]

  alias Sanctum.Context

  @doc """
  Get a policy by component reference, scoped to the given tenant context.

  Returns `{:ok, row}` or `{:error, :not_found}`.
  """
  @spec get_policy(Context.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :database_error}
  def get_policy(%Context{} = ctx, component_ref) when is_binary(component_ref) do
    cache_key = {:policy, component_ref, ctx.org_id, ctx.project_id}

    case Arca.Cache.get(cache_key) do
      {:ok, cached} -> {:ok, cached}
      :miss -> get_policy_from_db(ctx, component_ref)
    end
  end

  defp get_policy_from_db(ctx, component_ref) do
    # SQLite requires explicit column selection for schemaless queries
    query =
      from(p in "policies",
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
          allowed_paths: p.allowed_paths,
          allowed_actions: p.allowed_actions,
          batch_timeout: p.batch_timeout,
          max_concurrent_tasks: p.max_concurrent_tasks,
          allowed_private_ips: p.allowed_private_ips,
          inserted_at: p.inserted_at,
          updated_at: p.updated_at
        }
      )
      |> where_tenant(ctx)

    case Arca.Repo.one(query) do
      nil ->
        {:error, :not_found}

      row ->
        Arca.Cache.put({:policy, component_ref, ctx.org_id, ctx.project_id}, row)
        {:ok, row}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[Arca.PolicyStorage] Error in get_policy for #{component_ref}: #{Exception.message(e)}"
      )

      {:error, :database_error}
  end

  @doc """
  Save or update a policy, scoped to the given tenant context.

  Uses SQLite ON CONFLICT for upsert behavior.
  """
  @spec put_policy(Context.t(), map()) :: {:ok, map()} | {:error, term()}
  def put_policy(%Context{} = ctx, attrs) when is_map(attrs) do
    attrs = ensure_tenant_fields(ctx, attrs)

    Arca.Repo.insert_all(
      "policies",
      [attrs],
      on_conflict:
        {:replace,
         [
           :allowed_domains,
           :allowed_methods,
           :rate_limit_requests,
           :rate_limit_window_seconds,
           :timeout,
           :max_memory_bytes,
           :max_request_size,
           :max_response_size,
           :allowed_tools,
           :allowed_paths,
           :allowed_actions,
           :batch_timeout,
           :max_concurrent_tasks,
           :allowed_private_ips,
           :updated_at
         ]},
      conflict_target: [:component_ref, :org_id, :project_id]
    )
    |> case do
      {1, _} ->
        ref = attrs["component_ref"] || attrs[:component_ref]
        Arca.Cache.invalidate({:policy, ref, ctx.org_id, ctx.project_id})
        {:ok, attrs}

      {0, _} ->
        ref = attrs["component_ref"] || attrs[:component_ref]
        Arca.Cache.invalidate({:policy, ref, ctx.org_id, ctx.project_id})
        {:ok, attrs}

      error ->
        {:error, error}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.PolicyStorage] Error in put_policy: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Delete a policy by component reference, scoped to the given tenant context.
  """
  @spec delete_policy(Context.t(), String.t()) :: :ok | {:error, term()}
  def delete_policy(%Context{} = ctx, component_ref) when is_binary(component_ref) do
    query =
      from(p in "policies", where: p.component_ref == ^component_ref)
      |> where_tenant(ctx)

    case Arca.Repo.delete_all(query) do
      {_count, _} ->
        Arca.Cache.invalidate({:policy, component_ref, ctx.org_id, ctx.project_id})
        :ok

      error ->
        {:error, error}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.PolicyStorage] Error in delete_policy: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  List all policies, scoped to the given tenant context.
  """
  @spec list_policies(Context.t()) :: {:ok, [map()]} | {:error, term()}
  def list_policies(%Context{} = ctx) do
    # SQLite requires explicit column selection for schemaless queries
    query =
      from(p in "policies",
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
          allowed_paths: p.allowed_paths,
          allowed_actions: p.allowed_actions,
          batch_timeout: p.batch_timeout,
          max_concurrent_tasks: p.max_concurrent_tasks,
          allowed_private_ips: p.allowed_private_ips,
          inserted_at: p.inserted_at,
          updated_at: p.updated_at
        }
      )
      |> where_tenant(ctx)

    {:ok, Arca.Repo.all(query)}
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.PolicyStorage] Error in list_policies: #{Exception.message(e)}")
      {:error, :database_error}
  end

  defp ensure_tenant_fields(%Context{} = ctx, attrs) do
    put = fn map, key, val ->
      if Map.has_key?(map, key) or Map.has_key?(map, to_string(key)) do
        map
      else
        Map.put(map, key, val)
      end
    end

    attrs
    |> put.(:org_id, Arca.QueryHelpers.normalize_org_id(ctx.org_id))
    |> put.(:project_id, ctx.project_id || "default")
  end
end
