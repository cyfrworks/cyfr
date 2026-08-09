# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.QueryHelpers do
  @moduledoc """
  Shared Ecto query helpers for Arca storage modules.

  ## Canonical tenant-sentinel normalization

  SQLite treats `NULL != NULL` in unique indexes, so the single-tenant
  default deployment uses fixed sentinels: `org_id = "local"` and
  `project_id = "default"`. `normalize_org_id/1` and `normalize_project_id/1`
  are the **single** source of truth for that mapping — `nil` *and* `""`
  collapse to the canonical sentinel so a caller passing `""` and a caller
  passing `nil`/`"default"` always resolve to the *same* partition. Storage
  modules must route every tenant column read/write/cache-key through these
  helpers rather than open-coding `|| "default"` / `nil` matches (which
  previously diverged and could split the sentinel tenant across partitions).

  ## Relationship to the trust boundary

  These helpers are a fail-closed **backstop**, not the authoritative tenant
  control. The authoritative per-record tenant + permission decision is
  `Sanctum.Context.authorize/3` (via `Sanctum.TenantPolicy`).
  `where_tenant/3` — the context-taking entry every tenant-scoped store
  queries through — scopes the query to the context's org/project and raises
  for an authenticated non-platform context whose org_id is still nil/`""`:
  such a context bypassed the Sanctum chokepoint
  (`Sanctum.Context.require_tenant!/1`), and silently normalizing it to the
  seeded `"local"` org would read that org's rows. `where_org_id/2` /
  `where_project_id/2` are plain normalizing filters for bare-key call sites
  (org/project strings, no context to judge). Callers must not rely on any of
  these as the primary control.
  """

  import Ecto.Query

  @doc """
  Normalize an org_id to its canonical sentinel.

  `nil` and `""` both map to `"local"` — the single-user tenant sentinel.
  """
  @spec normalize_org_id(String.t() | nil) :: String.t()
  def normalize_org_id(nil), do: Arca.Tenant.local_org()
  def normalize_org_id(""), do: Arca.Tenant.local_org()
  def normalize_org_id(org_id) when is_binary(org_id), do: org_id

  @doc """
  Normalize a project_id to its canonical sentinel.

  `nil` and `""` both map to `"default"` (the canonical project sentinel).
  """
  @spec normalize_project_id(String.t() | nil) :: String.t()
  def normalize_project_id(nil), do: Arca.Tenant.default_project()
  def normalize_project_id(""), do: Arca.Tenant.default_project()
  def normalize_project_id(project_id) when is_binary(project_id), do: project_id

  @doc """
  Add an org_id filter to a query, scoping to the canonical org sentinel.

  nil/"" canonicalize to the seeded `"local"` org. This is the plain
  normalizing filter for bare-key call sites (API-key / permission / webhook
  lookups that carry an org string, not a context — there is no scope or
  authentication state to judge here). Context-driven queries go through
  `where_tenant/3`, which owns the org-less fail-closed rejection.
  """
  @spec where_org_id(Ecto.Queryable.t(), String.t() | nil) :: Ecto.Query.t()
  def where_org_id(query, org_id) do
    from(q in query, where: q.org_id == ^normalize_org_id(org_id))
  end

  @doc """
  Scope a query to the tenant identified by the given context.

  Applies both `org_id` and `project_id` filters by default.
  Pass `skip_project: true` to filter by org_id only.

  Fail-closed backstop: raises `ArgumentError` for an authenticated
  non-platform context whose org_id is nil/`""` — such a context bypassed
  `Sanctum.Context.require_tenant!/1`, and normalizing it to the seeded
  `"local"` org would silently read that org's rows. `:platform` is exempt
  (system/scheduled contexts legitimately cross tenants), as are
  unauthenticated contexts (the public context has no tenant to protect and
  is rejected from tenant-scoped routes upstream).
  """
  @spec where_tenant(Ecto.Queryable.t(), Sanctum.Context.t(), keyword()) :: Ecto.Query.t()
  def where_tenant(query, %Sanctum.Context{} = ctx, opts \\ []) do
    # An authenticated tenant context must carry a resolved org before it may
    # scope a query — every store inherits this guard uniformly through the
    # single context-taking entry. Exempting :platform is symmetric with
    # `Sanctum.Context.require_tenant!/1` and `Arca.Storage.tenant_segments/1`.
    if ctx.authenticated and ctx.scope != :platform and ctx.org_id in [nil, ""] do
      raise ArgumentError,
            "Arca.QueryHelpers.where_tenant/3: a resolved org_id is required " <>
              "(user_id=#{inspect(ctx.user_id)} scope=#{inspect(ctx.scope)} " <>
              "auth_method=#{inspect(ctx.auth_method)})"
    end

    query = where_org_id(query, ctx.org_id)

    if Keyword.get(opts, :skip_project, false) do
      query
    else
      where_project_id(query, ctx.project_id)
    end
  end

  @doc """
  Add a project_id filter to a query, scoping to the canonical project sentinel.
  """
  @spec where_project_id(Ecto.Queryable.t(), String.t() | nil) :: Ecto.Query.t()
  def where_project_id(query, project_id) do
    normalized = normalize_project_id(project_id)
    from(q in query, where: q.project_id == ^normalized)
  end

  @doc """
  Conditionally add a key-value pair to a keyword list.
  Returns the keyword list unchanged if the value is nil.
  """
  @spec maybe_put(keyword(), atom(), any()) :: keyword()
  def maybe_put(opts, _key, nil), do: opts
  def maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
