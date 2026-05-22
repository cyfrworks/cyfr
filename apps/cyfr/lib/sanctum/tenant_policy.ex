# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TenantPolicy do
  @moduledoc """
  Tenant boundary enforcement on resource access.

  Called from `Sanctum.Context.authorize/3` and the tenant gate:

  - `:platform` scope bypasses tenant checks (system/operator tasks).
  - `org_id` is required: `nil`/`""` are rejected with `:missing_tenant`. An
    authenticated context that has not resolved an org (via
    `Sanctum.Tenancy.resolve_into/2`) carries a nil org and is rejected here.
  - When both context and record carry an org/project, equality is required;
    a mismatch logs and returns an error.
  """

  alias Sanctum.Context
  require Logger

  @spec require_org(Context.t()) :: :ok | {:error, term()}
  def require_org(%Context{org_id: nil}), do: {:error, :missing_tenant}
  def require_org(%Context{org_id: ""}), do: {:error, :missing_tenant}
  def require_org(%Context{}), do: :ok

  @spec verify(Context.t(), map()) :: :ok | {:error, String.t()}
  def verify(%Context{scope: :platform}, _record), do: :ok

  def verify(%Context{org_id: org_id}, _record) when org_id in [nil, ""],
    do: {:error, "Unauthorized: a resolved org_id is required"}

  def verify(%Context{} = ctx, record) do
    # Normalize both sides so the seeded single-user sentinels compare equal:
    # a legacy/empty org canonicalizes to "local" and a nil project to
    # "default", matching how the storage layer partitions rows. Real
    # cross-tenant access (distinct non-sentinel orgs) still mismatches.
    record_org = Arca.QueryHelpers.normalize_org_id(Map.get(record, :org_id))
    record_proj = Arca.QueryHelpers.normalize_project_id(Map.get(record, :project_id))
    ctx_org = Arca.QueryHelpers.normalize_org_id(ctx.org_id)
    ctx_proj = Arca.QueryHelpers.normalize_project_id(ctx.project_id)

    if ctx_org == record_org and ctx_proj == record_proj do
      :ok
    else
      Logger.warning(
        "[Sanctum.TenantPolicy] Tenant mismatch: " <>
          "ctx=#{ctx_org}/#{ctx_proj} record=#{record_org}/#{record_proj} " <>
          "user=#{ctx.user_id}"
      )

      {:error, "Unauthorized: tenant mismatch"}
    end
  end
end
