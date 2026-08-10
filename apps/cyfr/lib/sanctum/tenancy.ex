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

  @doc """
  List the workspaces (org + project pairs) the context may switch into.

  A platform admin sees every org and its projects; a member sees only the
  orgs/projects their memberships grant. This is the *authorization ceiling* for
  the active-workspace switcher — the broadest set the principal may operate in,
  distinct from the single workspace they are currently scoped to. Returns a list
  of `%{org_id, org_name, project_id, project_name}` maps.
  """
  @spec list_workspaces(Context.t()) :: [map()]
  def list_workspaces(%Context{scope: :platform}) do
    Sanctum.Tenancy.Orgs.list(limit: 200)
    |> ensure_list()
    |> Enum.flat_map(&projects_of/1)
  end

  def list_workspaces(%Context{user_id: user_id}) when is_binary(user_id) do
    user_id
    |> Memberships.list_by_user()
    |> ensure_list()
    |> Enum.flat_map(&workspaces_for_membership/1)
    |> Enum.uniq_by(&{&1.org_id, &1.project_id})
  end

  def list_workspaces(_), do: []

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
        apply_membership(ctx, memberships)

      {:error, reason} ->
        Logger.error("[Sanctum.Tenancy] resolve failed for #{user_id}: #{inspect(reason)}")
        ctx
    end
  end

  # Set scope/org/project from the broadest of an already-loaded membership list.
  #
  # A platform membership row carries no org (`m.org_id == nil`). It still
  # resolves to a concrete working workspace — the seeded local sentinel — so the
  # context never carries an empty/`""` org downstream. The platform ceiling
  # lives in `scope`, not in an absent org; cross-tenant reach is preserved by
  # `scope: :platform`.
  defp apply_membership(%Context{} = ctx, memberships) do
    m = highest_scope(memberships)

    %{
      ctx
      | scope: String.to_existing_atom(m.scope),
        org_id: m.org_id || Arca.Tenant.local_org(),
        project_id: m.project_id || default_project(m.org_id) || Arca.Tenant.default_project()
    }
  end

  @doc """
  Re-validate a *restored* session context against the user's CURRENT
  memberships, returning the corrected context.

  Sessions persist `(scope, org_id, project_id)` so the per-request hot path
  doesn't re-resolve, but a membership change after a session was created MUST
  take effect immediately — otherwise a revoked platform admin keeps platform
  reach until the session TTL expires. This recomputes the authoritative scope
  from current memberships and keeps the session's selected workspace ONLY if it
  is still within the (current) authorization ceiling; otherwise it falls back to
  the broadest current membership. A user with no memberships is dropped to an
  org-less context (the tenant gate then rejects tenant-scoped routes).

  Cost: this issues one `Memberships.list_by_user/1` query per restored request
  (small, indexed by `user_id`, limit 50 — scales with DB latency, not data
  size). It trades that query for immediate revocation instead of waiting out
  the session TTL. If profiling ever shows DB latency dominating on a
  high-throughput deployment, add a short (30–60s) membership cache rather than
  reverting to trusting the persisted scope.

  Failing safe: on a transient membership-read error the context is returned
  unchanged rather than locking the user out or silently re-resolving.
  """
  @spec revalidate(Context.t()) :: Context.t()
  def revalidate(%Context{user_id: user_id, org_id: org, project_id: project} = ctx)
      when is_binary(user_id) do
    case Memberships.list_by_user(user_id) do
      memberships when is_list(memberships) and memberships != [] ->
        if is_binary(org) and org != "" and workspace_granted?(memberships, org, project) do
          # Selected workspace still authorized — keep it, but pin scope to the
          # authoritative (current) ceiling so a stale elevated scope can't ride.
          %{ctx | scope: ceiling_scope(memberships)}
        else
          # Selected workspace no longer authorized (membership removed/changed,
          # or org-less) — fall back to the broadest current membership.
          apply_membership(ctx, memberships)
        end

      [] ->
        %{ctx | scope: :project, org_id: nil, project_id: nil}

      _error ->
        ctx
    end
  end

  def revalidate(%Context{} = ctx), do: ctx

  @doc """
  Whether `user_id` still holds a membership granting `org_id`.

  Deferred-authority ingresses (webhooks, cron schedules) execute on behalf
  of the user who created them, possibly long after that user lost access —
  the stored row must not remain a standing execution channel for a departed
  principal. With no `:auth_provider` configured there are no memberships to
  consult (the operator is the only user), so every stored owner is active.
  On a transient membership-read error the check fails safe (active),
  matching `revalidate/1`'s posture — a DB blip must not silently kill every
  schedule; the read is retried on the next firing.
  """
  @spec user_active_in_org?(String.t() | nil, String.t() | nil) :: boolean()
  def user_active_in_org?(user_id, org_id) do
    cond do
      not Sanctum.auth_configured?() ->
        true

      not (is_binary(user_id) and user_id != "") ->
        false

      true ->
        case Memberships.list_by_user(user_id) do
          memberships when is_list(memberships) ->
            Enum.any?(memberships, fn
              %{scope: "platform"} -> true
              %{org_id: m_org} -> m_org == org_id
              _ -> false
            end)

          error ->
            Logger.warning(
              "[Sanctum.Tenancy] membership read failed during owner re-check for " <>
                "user=#{user_id}: #{inspect(error)} — allowing this firing"
            )

            true
        end
    end
  end

  # Is the workspace `(org, project)` reachable under these memberships?
  # Platform grants every workspace; an org membership grants its org; a project
  # membership grants exactly its (org, project).
  defp workspace_granted?(memberships, org, project) do
    Enum.any?(memberships, fn
      %{scope: "platform"} -> true
      %{scope: "org", org_id: m_org} -> m_org == org
      %{scope: "project", org_id: m_org, project_id: m_proj} -> m_org == org and m_proj == project
      _ -> false
    end)
  end

  defp ceiling_scope(memberships) do
    String.to_existing_atom(highest_scope(memberships).scope)
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
        Arca.Tenant.default_project()

      {:error, reason} ->
        Logger.error(
          "[Sanctum.Tenancy] failed to resolve default project for org #{org_id}: #{inspect(reason)}"
        )

        Arca.Tenant.default_project()
    end
  end

  defp ensure_list(list) when is_list(list), do: list
  defp ensure_list(_), do: []

  # Every project within an org (platform admins and org-scoped members).
  defp projects_of(%{id: org_id} = org) do
    org_id
    |> Sanctum.Tenancy.Projects.list_by_org(limit: 200)
    |> ensure_list()
    |> Enum.map(&workspace_entry(org, &1))
  end

  defp workspaces_for_membership(%{scope: "org", org_id: org_id}) when is_binary(org_id) do
    case Sanctum.Tenancy.Orgs.get(org_id) do
      {:ok, org} -> projects_of(org)
      _ -> []
    end
  end

  # A project-scoped membership grants exactly one workspace.
  defp workspaces_for_membership(%{scope: "project", org_id: org_id, project_id: pid})
       when is_binary(org_id) and is_binary(pid) do
    with {:ok, org} <- Sanctum.Tenancy.Orgs.get(org_id),
         {:ok, project} <- Sanctum.Tenancy.Projects.get(pid) do
      [workspace_entry(org, project)]
    else
      _ -> []
    end
  end

  # Platform memberships are handled by the :platform list_workspaces head; an
  # org-less or unrecognized membership grants nothing switchable here.
  defp workspaces_for_membership(_), do: []

  defp workspace_entry(org, project) do
    %{
      org_id: org.id,
      org_name: org.name || org.slug || org.id,
      project_id: project.id,
      project_name: project.name || project.slug || project.id
    }
  end

  # Uniform admin bootstrap. An email listed in CYFR_PLATFORM_ADMIN_EMAILS gets
  # a platform-scope membership minted on sign-in. Idempotent.
  #
  # This is the widest grant in the system and its only input is an email
  # address, so it is audited rather than silent: under a generic OIDC issuer
  # `email_verified` may legitimately be absent (see
  # `Sanctum.Auth.EmailVerification`), which means the address is asserted by
  # the issuer rather than proven. An operator needs to be able to see when the
  # grant was minted and for whom.
  defp maybe_bootstrap_platform_admin(user_id, email)
       when is_binary(user_id) and is_binary(email) do
    if email_match?(email, Application.get_env(:cyfr, :platform_admin_emails, [])) do
      already_admin? =
        Enum.any?(Memberships.list_by_user(user_id), &(&1.scope == "platform"))

      case Memberships.ensure(user_id, scope: "platform") do
        {:ok, _membership} ->
          if already_admin?, do: :ok, else: emit_platform_bootstrap(user_id, email)

        {:error, reason} ->
          Logger.error(
            "[Sanctum.Tenancy] platform admin bootstrap failed for #{user_id}: #{inspect(reason)}"
          )
      end
    end

    :ok
  end

  defp maybe_bootstrap_platform_admin(_user_id, _email), do: :ok

  defp emit_platform_bootstrap(user_id, email) do
    Logger.warning(
      "[Sanctum.Tenancy] minted platform-scope membership for #{user_id} " <>
        "(matched CYFR_PLATFORM_ADMIN_EMAILS)"
    )

    :telemetry.execute(
      [:cyfr, :sanctum, :tenancy, :platform_admin_bootstrap],
      %{count: 1},
      %{user_id: user_id, email: email}
    )

    :ok
  end

  defp email_match?(email, list) when is_list(list), do: String.downcase(email) in list
  defp email_match?(_email, _list), do: false
end
