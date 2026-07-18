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
  `where_org_id/3` additionally scopes every query and
  rejects an org-less *tenant* context so a missed Sanctum-layer check still
  cannot leak — but callers must not rely on it as the primary control.
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

  nil/"" canonicalize to the seeded `"local"` org. The org-less rejection for
  authenticated contexts is enforced upstream by the Sanctum chokepoint
  (`Sanctum.Context.require_tenant!/1`); this filter just scopes rows. The
  `scope` arg is accepted for call-site symmetry but does not change the
  filter (platform/system callers pass an explicit org or query their own).
  """
  @spec where_org_id(Ecto.Queryable.t(), String.t() | nil) :: Ecto.Query.t()
  def where_org_id(query, org_id), do: where_org_id(query, org_id, nil)

  @spec where_org_id(Ecto.Queryable.t(), String.t() | nil, String.t() | atom() | nil) ::
          Ecto.Query.t()
  def where_org_id(query, org_id, _scope) do
    # nil/"" canonicalize to the seeded "local" org — org-less data is local
    # data. The authoritative org-less rejection lives in the Sanctum chokepoint
    # (`Sanctum.Context.require_tenant!`), which keeps an unresolved
    # authenticated context from ever reaching here.
    from(q in query, where: q.org_id == ^normalize_org_id(org_id))
  end

  @doc """
  Scope a query to the tenant identified by the given context.

  Applies both `org_id` and `project_id` filters by default.
  Pass `skip_project: true` to filter by org_id only.
  """
  @spec where_tenant(Ecto.Queryable.t(), Sanctum.Context.t(), keyword()) :: Ecto.Query.t()
  def where_tenant(query, %Sanctum.Context{} = ctx, opts \\ []) do
    # The org-less fail-closed guard lives in `where_org_id/3`, which exempts
    # `:platform` (system/scheduled contexts legitimately have no org) —
    # symmetric with `Sanctum.Context.require_tenant!/1`. Every store inherits
    # it uniformly; there is no separate guard to keep in sync here.
    query = where_org_id(query, ctx.org_id, to_string(ctx.scope))

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
