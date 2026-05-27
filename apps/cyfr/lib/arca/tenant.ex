# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Tenant do
  @moduledoc """
  Canonical workspace sentinels — the single source of truth for the default
  tenant coordinates.

  Single-tenant and not-yet-resolved rows use fixed string sentinels rather
  than `NULL`, because SQLite treats `NULL != NULL` in unique indexes (two
  org-less rows would otherwise be considered distinct). `local_org/0` and
  `default_project/0` are those sentinels; `Arca.QueryHelpers.normalize_org_id/1`
  and `normalize_project_id/1` map `nil`/`""` onto them.

  This is a persistence mechanic, not product policy: Arca knows the *value*
  of the seeded default workspace; deciding *when* a caller defaults into it
  (e.g. a platform admin's working workspace) is `Sanctum.Tenancy`'s job.
  """

  @local_org "local"
  @default_project "default"

  @doc "The seeded single-tenant org sentinel (`\"local\"`)."
  @spec local_org() :: String.t()
  def local_org, do: @local_org

  @doc "The seeded default project sentinel (`\"default\"`)."
  @spec default_project() :: String.t()
  def default_project, do: @default_project
end
