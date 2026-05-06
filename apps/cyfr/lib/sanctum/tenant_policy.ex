defmodule Sanctum.TenantPolicy do
  @moduledoc """
  Behaviour for tenant boundary enforcement on resource access.

  Called from `Sanctum.Context.authorize/3` to decide whether a context may
  access a record. Core's default `Sanctum.PermissiveTenantPolicy` allows
  contexts with `org_id: nil` (single-user / co-admin Core deployments don't
  have orgs) and enforces tenant equality when both sides have an org_id.
  Arx ships `Arx.Sanctum.TenantPolicy` which additionally rejects nil org_id.

  Wired via `config :cyfr, :tenant_policy, Mod`.
  """

  @callback verify(ctx :: Sanctum.Context.t(), record :: map()) ::
              :ok | {:error, String.t()}

  @doc """
  Verify that the context has a non-nil org_id.

  Used at boundary checks (API key creation, MCP session resolution, web
  authentication, webhook invocation) where Arx requires every tenant-scoped
  operation to have a resolved org. Core's permissive policy returns `:ok`
  unconditionally (Core has no org concept).

  ## Examples

      # Core (Sanctum.PermissiveTenantPolicy):
      ctx = Sanctum.Context.build(user_id: "u1", org_id: nil)
      Sanctum.PermissiveTenantPolicy.require_org(ctx)
      #=> :ok

      # Arx (Arx.Sanctum.TenantPolicy):
      ctx = Sanctum.Context.build(user_id: "u1", org_id: nil)
      Arx.Sanctum.TenantPolicy.require_org(ctx)
      #=> {:error, :missing_tenant}

      ctx = Sanctum.Context.build(user_id: "u1", org_id: "acme-corp")
      Arx.Sanctum.TenantPolicy.require_org(ctx)
      #=> :ok
  """
  @callback require_org(ctx :: Sanctum.Context.t()) :: :ok | {:error, term()}
end
