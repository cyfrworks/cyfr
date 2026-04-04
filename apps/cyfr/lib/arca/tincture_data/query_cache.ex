defmodule Arca.TinctureData.QueryCache do
  @moduledoc """
  Cache wrapper for tincture query results with org/project-scoped keys.

  Delegates to `Arca.Cache` (ETS-based) with structured cache keys
  that include tenant isolation dimensions.
  """

  alias Sanctum.Context

  @default_ttl_ms 30_000

  @doc """
  Look up a cached query result.
  """
  @spec get(Context.t(), String.t(), String.t(), String.t(), binary()) :: {:ok, term()} | :miss
  def get(%Context{} = ctx, publisher, tincture_name, query_name, params_hash) do
    key = cache_key(ctx, publisher, tincture_name, query_name, params_hash)
    Arca.Cache.get(key)
  end

  @doc """
  Cache a query result with a TTL.
  """
  @spec put(Context.t(), String.t(), String.t(), String.t(), binary(), term(), non_neg_integer() | nil) ::
          :ok
  def put(%Context{} = ctx, publisher, tincture_name, query_name, params_hash, result, ttl_ms \\ nil) do
    key = cache_key(ctx, publisher, tincture_name, query_name, params_hash)
    Arca.Cache.put(key, result, ttl_ms || @default_ttl_ms)
    :ok
  end

  @doc """
  Invalidate all cached queries for a tincture.
  """
  @spec invalidate_tincture(Context.t(), String.t(), String.t()) :: :ok
  def invalidate_tincture(%Context{} = ctx, publisher, tincture_name) do
    {org_id, project_id} = extract_scope(ctx)
    Arca.Cache.delete_match({:tincture_query, org_id, project_id, publisher, tincture_name, :_, :_})
    :ok
  end

  @doc """
  Compute a deterministic hash for query params.
  """
  @spec params_hash(map()) :: binary()
  def params_hash(params) when is_map(params) do
    params
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp cache_key(ctx, publisher, tincture_name, query_name, params_hash) do
    {org_id, project_id} = extract_scope(ctx)
    {:tincture_query, org_id, project_id, publisher, tincture_name, query_name, params_hash}
  end

  defp extract_scope(%Context{} = ctx) do
    {Arca.QueryHelpers.normalize_org_id(ctx.org_id), ctx.project_id || "default"}
  end
end
