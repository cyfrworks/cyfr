defmodule Arca.TenantTestHelper do
  @moduledoc false

  alias Sanctum.Context

  @doc "Returns two contexts with different org_id and project_id."
  def two_contexts do
    ctx_a = Context.build(
      user_id: "user_a",
      org_id: "org_alpha",
      project_id: "proj_1",
      permissions: [:*],
      scope: :project,
      auth_method: :oidc,
      authenticated: true
    )

    ctx_b = Context.build(
      user_id: "user_b",
      org_id: "org_beta",
      project_id: "proj_2",
      permissions: [:*],
      scope: :project,
      auth_method: :oidc,
      authenticated: true
    )

    {ctx_a, ctx_b}
  end

  @doc "Returns two contexts sharing the same org but different projects."
  def same_org_contexts do
    ctx_a = Context.build(
      user_id: "user_a",
      org_id: "org_shared",
      project_id: "proj_1",
      permissions: [:*],
      scope: :project,
      auth_method: :oidc,
      authenticated: true
    )

    ctx_b = Context.build(
      user_id: "user_b",
      org_id: "org_shared",
      project_id: "proj_2",
      permissions: [:*],
      scope: :project,
      auth_method: :oidc,
      authenticated: true
    )

    {ctx_a, ctx_b}
  end
end
