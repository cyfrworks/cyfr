defmodule Sanctum.PermissiveTenantPolicy do
  @moduledoc """
  Default `Sanctum.TenantPolicy` impl for Core.

  - `:platform` scope bypasses tenant checks.
  - `org_id: nil` is allowed (Core single-user / co-admin deployments).
  - When both sides have an org/project, requires equality.

  Mirrors the verify_tenant logic that previously lived inline in
  `Sanctum.Context`. Arx's `Arx.Sanctum.TenantPolicy` adds a stricter
  check that rejects nil org_id, then delegates the equality check
  back to this module.
  """

  @behaviour Sanctum.TenantPolicy

  alias Sanctum.Context
  require Logger

  @impl true
  def require_org(_ctx), do: :ok

  @impl true
  def verify(%Context{scope: :platform}, _record), do: :ok
  def verify(%Context{org_id: nil}, _record), do: :ok

  def verify(%Context{} = ctx, record) do
    record_org = Map.get(record, :org_id) || ""
    record_proj = Map.get(record, :project_id) || "default"
    ctx_org = ctx.org_id || ""
    ctx_proj = ctx.project_id

    if ctx_org == record_org and ctx_proj == record_proj do
      :ok
    else
      Logger.warning(
        "[Sanctum.PermissiveTenantPolicy] Tenant mismatch: " <>
          "ctx=#{ctx_org}/#{ctx_proj} record=#{record_org}/#{record_proj} " <>
          "user=#{ctx.user_id}"
      )

      {:error, "Unauthorized: tenant mismatch"}
    end
  end
end
