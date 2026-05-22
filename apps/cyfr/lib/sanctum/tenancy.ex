# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy do
  @moduledoc """
  Tenant resolution from memberships.

  `resolve_into/2` is the single chokepoint every auth path flows through to
  attach the caller's scope/org/project to their Context. It reads the user's
  membership rows and applies the broadest one (platform > org > project).

  There is no deployment "mode". A fresh install with no auth configured never
  reaches here (requests run as the unauthenticated public context). When auth
  is configured, the operator declares platform admins via
  `CYFR_PLATFORM_ADMIN_EMAILS`; the first sign-in of a listed email mints a
  platform-scope membership. Everyone else is admitted only by an existing
  membership row.

  ## Test overrides

  Tests can bypass membership resolution by setting
  `config :cyfr, :tenancy_resolver_override, MyResolver` — the override's
  `resolve/1` runs instead. This is honored only when the compile-time flag
  `config :cyfr, :allow_tenancy_resolver_override, true` is set (test/dev);
  production releases compile it out entirely, so the override can never run.
  """

  require Logger
  alias Sanctum.Context
  alias Sanctum.Tenancy.Memberships

  @doc """
  Merge the caller's scope/org/project into the context.

  Without `force: true`, no-ops when the context already carries a non-empty
  `org_id` (the per-request safety-net usage in plugs: the stored value was
  resolved at session-create time and re-querying every request is wasteful).
  Auth paths that produce a Context *before* membership has been resolved —
  `Sanctum.Auth.OAuth`, `Sanctum.Auth.DeviceFlow`, `Sanctum.Auth.OIDC` — pass
  `force: true`.

  Resolution failure logs and returns the context unchanged — a context with no
  resolved org is rejected downstream by the tenant gate
  (`Sanctum.Context.tenant_ok/1`).
  """
  @spec resolve_into(Context.t(), keyword()) :: Context.t()
  def resolve_into(ctx, opts \\ [])

  def resolve_into(%Context{org_id: org} = ctx, opts)
      when is_binary(org) and org != "" do
    if Keyword.get(opts, :force, false), do: do_resolve(ctx), else: ctx
  end

  def resolve_into(%Context{} = ctx, _opts), do: do_resolve(ctx)

  # The membership-resolution override is a test-only seam. `do_resolve/1` is
  # defined in two compile-time variants: a production release — compiled with
  # prod config, where the flag is false — gets the plain membership path with
  # NO override code at all, so the override can never bypass membership
  # resolution regardless of how `:cyfr` app env is set at runtime.
  if Application.compile_env(:cyfr, :allow_tenancy_resolver_override, false) do
    defp do_resolve(%Context{} = ctx) do
      case Application.get_env(:cyfr, :tenancy_resolver_override) do
        nil ->
          resolve_from_memberships(ctx)

        module ->
          case module.resolve(ctx.user_id) do
            %{org_id: org_id} = membership ->
              %{
                ctx
                | org_id: org_id,
                  project_id: Map.get(membership, :project_id) || ctx.project_id
              }

            :no_membership ->
              ctx

            {:error, reason} ->
              Logger.error(
                "[Sanctum.Tenancy] resolve override failed for #{ctx.user_id}: #{inspect(reason)}"
              )

              ctx
          end
      end
    end
  else
    defp do_resolve(%Context{} = ctx), do: resolve_from_memberships(ctx)
  end

  defp resolve_from_memberships(%Context{} = ctx) do
    maybe_bootstrap_platform_admin(ctx.user_id, ctx.email)
    apply_highest_membership(ctx)
  end

  defp apply_highest_membership(%Context{user_id: user_id} = ctx) do
    case Memberships.list_by_user(user_id) do
      [] ->
        # No membership → org_id stays as-is (nil for a fresh auth ctx) and the
        # tenant gate rejects on tenant-scoped routes.
        ctx

      memberships when is_list(memberships) ->
        m = highest_scope(memberships)

        %{
          ctx
          | scope: String.to_existing_atom(m.scope),
            org_id: m.org_id || ctx.org_id,
            project_id: m.project_id || default_project(m.org_id) || ctx.project_id
        }

      {:error, reason} ->
        Logger.error("[Sanctum.Tenancy] resolve failed for #{user_id}: #{inspect(reason)}")
        ctx
    end
  end

  # Broadest scope wins: platform grants everything, then org, then project.
  defp highest_scope(memberships) do
    Enum.min_by(memberships, fn
      %{scope: "platform"} -> 0
      %{scope: "org"} -> 1
      %{scope: "project"} -> 2
      _ -> 3
    end)
  end

  # The org's first project, or "default" when none exist yet. Single source for
  # the default-project decision (previously duplicated in the OIDC provider).
  defp default_project(nil), do: nil

  defp default_project(org_id) do
    case Sanctum.Tenancy.Projects.list_by_org(org_id, limit: 1) do
      [project | _] ->
        project.id

      [] ->
        "default"

      {:error, reason} ->
        Logger.error(
          "[Sanctum.Tenancy] failed to resolve default project for org #{org_id}: #{inspect(reason)}"
        )

        "default"
    end
  end

  # Uniform admin bootstrap. An email listed in CYFR_PLATFORM_ADMIN_EMAILS gets
  # a platform-scope membership minted on sign-in. Idempotent.
  defp maybe_bootstrap_platform_admin(user_id, email)
       when is_binary(user_id) and is_binary(email) do
    if email_match?(email, Application.get_env(:cyfr, :platform_admin_emails, [])) do
      Memberships.ensure(user_id, scope: "platform")
    end

    :ok
  end

  defp maybe_bootstrap_platform_admin(_user_id, _email), do: :ok

  defp email_match?(email, list) when is_list(list), do: String.downcase(email) in list
  defp email_match?(_email, _list), do: false
end
