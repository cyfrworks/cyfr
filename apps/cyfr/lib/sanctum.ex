# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum do
  @moduledoc """
  Identity and authorization layer for CYFR.

  Sanctum is the gatekeeper for all CYFR operations. It manages:
  - **Authentication**: Who is making the request (OAuth, API keys)
  - **Authorization**: What they're allowed to do (permissions)
  - **Context**: The execution context that flows through all services

  ## CLI authentication

  Uses OAuth Device Flow for CLI authentication:

      # User runs: cyfr login
      # After auth completes:
      {:ok, ctx} = Sanctum.authenticate(params)

  ## Configurable Auth Provider

  With a configurable OIDC auth provider, uses full OIDC authentication:

      {:ok, ctx} = Sanctum.authenticate(params)

  ## Configuration

      config :cyfr,
        auth_provider: Sanctum.Auth.OAuth  # or the configured auth provider

  """

  alias Sanctum.Context

  @doc """
  Get current Context from request connection.
  """
  def current_user(conn) do
    auth_provider().current_user(conn)
  end

  @doc """
  Authenticate with provided credentials/params.
  """
  def authenticate(params) do
    auth_provider().authenticate(params)
  end

  @doc """
  True when an auth provider is configured.

  When false, requests run as the unauthenticated public context and the
  instance is operated by a single trusted operator — so operator-only
  conveniences (private-IP egress, host-filesystem artifact reads, broad
  anonymous browsing) are safe. When true, untrusted signed-in users may be
  present, so those are locked down.
  """
  @spec auth_configured?() :: boolean()
  def auth_configured?, do: not is_nil(Application.get_env(:cyfr, :auth_provider))

  @doc """
  Server-internal context for background/system operations — sweepers, health
  checks, retention, cache sweep, audit fan-out, secret-store bootstrap,
  execution-record write-back.

  Returns a `scope: :platform`, `auth_method: :system` context with
  `user_id: "system"`. Platform scope bypasses
  tenant boundary checks (`Sanctum.TenantPolicy.verify/2`), correctly modeling
  system tasks that cross tenant boundaries. Distinct from cron, which uses
  `Sanctum.Context.for_scheduled/2` (`auth_method: :scheduled`).

  Thin facade over the single builder `Sanctum.Context.internal/1`.
  """
  def system_context, do: Context.internal([])

  @doc """
  Facade over the single server-internal context builder
  `Sanctum.Context.internal/1`. See that function for the full option list.

  Use this for any server-constructed context that needs non-default
  coordinates — a per-user namespace/tenant for an audit write-back, a
  narrower permission set, or a project scope.
  """
  @spec internal_context(keyword()) :: Context.t()
  def internal_context(opts \\ []), do: Context.internal(opts)

  # Namespace for public (unauthenticated) tincture execution. A leading
  # underscore cannot be a real claimed namespace (claimed slugs match
  # ^[a-z0-9]+(-[a-z0-9]+)*$), so this is collision-proof by construction —
  # the same guarantee `"_system"` relies on — while keeping public-tincture
  # execution in its own isolated, audit-distinct namespace (not conflated
  # with system tasks).
  @public_tincture_namespace "_tincture"

  @doc """
  Build the scoped execution context for a tincture invocation.

  This is the *invoke* path (the tincture's catalyst runs with `:execute`). For
  serving a tincture's static assets / looking it up without executing anything,
  use `Cyfr.TinctureHelpers.build_public_context/2` instead.

  Single source of truth (previously duplicated in the tincture controller
  and the Prism shell LiveView). Uses the dedicated `:tincture` auth_method
  so it is valid whether or not an auth provider is configured and flows
  through the unified authorization path.

  For an authenticated request, the caller's real `user_id` and `namespace`
  are carried through for the audit trail (namespace is identity-only and may
  be nil); a public request falls back to the tincture identity and the
  dedicated public-tincture namespace tag. The org/project tenant coordinates
  are inherited from the caller and the context stays project-scoped (NOT
  platform-scoped) so any configured tenant isolation still applies to the
  invocation.
  """
  @spec build_tincture_context(Context.t(), map()) :: Context.t()
  def build_tincture_context(%Context{} = caller_ctx, tincture) do
    tincture_id = "tincture:#{tincture.publisher}.#{tincture.name}"

    # Key on `authenticated` (the real signal), NOT on namespace presence — an
    # authenticated user may legitimately have a nil namespace (identity-only,
    # not required). Their namespace passes through for attribution; only a
    # genuinely public caller falls back to the public-tincture identity.
    #
    # An authenticated caller's invocation runs with the caller's OWN
    # permissions — no stronger, no weaker. A public caller gets exactly
    # [:execute] and is marked `anonymous`, which the credential planes
    # (Sanctum.Secrets, Sanctum.OAuth) deny: an anonymous internet request
    # must never be silently upgraded into a credential-bearing executor.
    {user_id, namespace, permissions, anonymous} =
      if caller_ctx.authenticated and is_binary(caller_ctx.user_id) do
        {caller_ctx.user_id, caller_ctx.namespace, caller_ctx.permissions, false}
      else
        {tincture_id, @public_tincture_namespace, [:execute], true}
      end

    Context.build(
      user_id: user_id,
      namespace: namespace,
      permissions: permissions,
      # Carries the caller's resolved org; a nil here flows through and the
      # tenant gate rejects downstream (a tincture cannot widen tenant scope).
      org_id: caller_ctx.org_id,
      project_id: caller_ctx.project_id,
      auth_method: :tincture,
      authenticated: true,
      anonymous: anonymous
    )
  end

  defp auth_provider do
    Application.get_env(:cyfr, :auth_provider) ||
      raise "No auth provider configured. Set config :cyfr, :auth_provider " <>
              "(the default OAuth provider is enabled by setting CYFR_GITHUB_CLIENT_ID)."
  end
end
