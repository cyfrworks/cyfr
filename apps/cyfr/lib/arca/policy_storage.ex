# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PolicyStorage do
  @moduledoc """
  Storage operations for Host Policies.

  This module provides the database layer for policy storage.
  Reads are cached via `Arca.Cache` for performance.

  Writes use `insert_all`/`update_all` and trust their caller: input validation
  lives in the `Sanctum.*` context layer, which is the only caller. Do not call
  these write functions with unvalidated external input.

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

  alias Arca.Schemas.Policy
  alias Sanctum.Context

  @doc """
  Get a policy by component reference, scoped to the given tenant context.

  Returns `{:ok, row}` or `{:error, :not_found}`.
  """
  @spec get_policy(Context.t(), String.t()) ::
          {:ok, Policy.t()} | {:error, :not_found | :database_error}
  def get_policy(%Context{} = ctx, component_ref) when is_binary(component_ref) do
    cache_key = {:policy, component_ref, ctx.org_id, ctx.project_id}

    case Arca.Cache.get(cache_key) do
      {:ok, cached} -> {:ok, cached}
      :miss -> get_policy_from_db(ctx, component_ref)
    end
  end

  defp get_policy_from_db(ctx, component_ref) do
    query =
      from(p in Policy,
        where: p.component_ref == ^component_ref,
        limit: 1
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

  Uses ON CONFLICT for upsert behavior.
  """
  @spec put_policy(Context.t(), map()) :: {:ok, map()} | {:error, term()}
  def put_policy(%Context{} = ctx, attrs) when is_map(attrs) do
    attrs = ensure_tenant_fields(ctx, attrs)

    Arca.Repo.insert_all(
      Policy,
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
           :is_public,
           :updated_at
         ]},
      conflict_target: [:component_ref, :org_id, :project_id]
    )
    |> case do
      {1, _} ->
        ref = attrs[:component_ref]
        Arca.Cache.invalidate({:policy, ref, ctx.org_id, ctx.project_id})
        {:ok, attrs}

      {0, _} ->
        ref = attrs[:component_ref]
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
      from(p in Policy, where: p.component_ref == ^component_ref)
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
  @spec list_policies(Context.t()) :: {:ok, [Policy.t()]} | {:error, term()}
  def list_policies(%Context{} = ctx) do
    query = from(p in Policy) |> where_tenant(ctx)

    {:ok, Arca.Repo.all(query)}
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.PolicyStorage] Error in list_policies: #{Exception.message(e)}")
      {:error, :database_error}
  end

  defp ensure_tenant_fields(%Context{} = ctx, attrs) do
    attrs
    |> Map.put_new(:org_id, Arca.QueryHelpers.normalize_org_id(ctx.org_id))
    |> Map.put_new(:project_id, Arca.QueryHelpers.normalize_project_id(ctx.project_id))
  end
end
