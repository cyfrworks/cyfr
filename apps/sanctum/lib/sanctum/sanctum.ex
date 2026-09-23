# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum do
  @moduledoc """
  Identity and authorization layer for CYFR.

  Sanctum is the gatekeeper for all CYFR operations. It manages:
  - **Authentication**: Who is making the request (OAuth, API keys)
  - **Authorization**: What they're allowed to do (permissions)
  - **Context**: The execution context that flows through all services

  ## Signing in

  A session is minted at exactly two places, and the door
  (`Sanctum.Door.admit_identity/2`) is asked first at both:

  - the browser flow — `EmissaryWeb.AuthController.callback/2` after the
    configured provider (`Sanctum.Auth.provider/0`: `Sanctum.Auth.OAuth`
    or `Sanctum.Auth.OIDC`) proves the identity;
  - the CLI flow — `Sanctum.Auth.DeviceFlow.poll_for_session/3` behind the
    `session` MCP tool (`cyfr login`).

  Providers prove who someone is; they never mint sessions themselves.

  ## Configuration

      config :sanctum,
        auth_provider: Sanctum.Auth.OAuth  # or the configured auth provider
  """

  alias Arca.Schemas.JobClaim
  alias Sanctum.Context

  @doc """
  True when an auth provider is configured.

  When false, requests run as the unauthenticated public context and the
  instance is operated by a single trusted operator — so operator-only
  conveniences (private-IP egress, host-filesystem artifact reads, broad
  anonymous browsing) are safe. When true, untrusted signed-in users may be
  present, so those are locked down.
  """
  @spec auth_configured?() :: boolean()
  def auth_configured?, do: not is_nil(Sanctum.Auth.provider())

  @doc """
  The externally reachable base URL of this instance, without a trailing
  slash, or `nil` when the operator has not declared one
  (`:sanctum, :public_url`, from `CYFR_PUBLIC_URL`).

  Only the operator knows it: behind a proxy or a tunnel it is neither
  the bind address nor the `Host` of any particular request. Two of this
  domain's surfaces face outward and need it — the URL a webhook sender
  is handed (`Sanctum.Webhook`) and the `redirect_uri` an OAuth provider
  returns to (`Sanctum.Vault.OAuthGrant`) — so it is read here once.
  """
  @spec public_url() :: String.t() | nil
  def public_url do
    case Application.get_env(:sanctum, :public_url) do
      url when is_binary(url) ->
        case String.trim_trailing(String.trim(url), "/") do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @doc """
  `public_url/0` when the operator declared one, otherwise the
  deployment's own origin (`:sanctum, :fallback_origin`, the endpoint's
  scheme, host and port).

  Distinct from `public_url/0` on purpose: a webhook URL is a *path* when
  nothing is declared, because handing a sender a guessed host is worse
  than handing it nothing, while an OAuth `redirect_uri` must be absolute
  or the flow cannot start at all. TLS deployments set `CYFR_PUBLIC_URL`.
  """
  @spec origin() :: String.t()
  def origin do
    public_url() || Application.get_env(:sanctum, :fallback_origin, "http://localhost:4000")
  end

  @doc """
  The boot's operator reconcile, under the `bootstrap` claim `claim`.

  The operator list (`CYFR_PLATFORM_ADMIN_EMAILS`) is validated and
  snapshotted here, once: a list of lowercased addresses, or
  `{:error, :malformed_configuration}` before any row is read. Storage
  then removes, in one transaction under the member slot and the claim,
  every platform grant whose person that snapshot no longer names, with
  all of that person's sessions (`Arca.Members.reconcile_platform/3`).
  Only after that commit are the removed sessions' established contexts
  dropped and their revocation announced.

  `opts`: `:slot` (`Arca.ControlPlane.held/0`'s slot, or `:none` where no
  member claims one) and `:lease_ms` (the claim lease the final renewal
  extends). Answers the renewed claim the caller releases, or the
  refusal; nothing is announced on a refusal, because nothing committed.
  """
  @spec reconcile_platform_admins(JobClaim.t(), keyword()) ::
          {:ok, JobClaim.t()} | {:error, atom()}
  def reconcile_platform_admins(%JobClaim{} = claim, opts) when is_list(opts) do
    with {:ok, operators} <- operator_snapshot(),
         {:ok, %{claim: renewed, revoked: revoked}} <-
           Arca.Members.reconcile_platform(Cyfr.Actor.system(), claim,
             slot: Keyword.fetch!(opts, :slot),
             lease_ms: Keyword.fetch!(opts, :lease_ms),
             operators: operators,
             policy_digest: policy_digest(operators)
           ) do
      for %{user_id: user_id, session_hashes: hashes} <- revoked do
        Sanctum.Session.announce_revoked(user_id, hashes)
      end

      {:ok, renewed}
    end
  end

  # The configured list, read as configured — the key `Sanctum.Door`
  # compares sign-ins against — and accepted only in the shape the door
  # assumes: a list of lowercased addresses with nothing around them.
  # Anything else is a configuration the reconcile cannot read, and
  # reading it loosely could keep an operator the list no longer names.
  defp operator_snapshot do
    case Application.get_env(:sanctum, :platform_admin_emails, []) do
      emails when is_list(emails) ->
        if Enum.all?(emails, &operator_email?/1),
          do: {:ok, emails |> Enum.uniq() |> Enum.sort()},
          else: {:error, :malformed_configuration}

      _malformed ->
        {:error, :malformed_configuration}
    end
  end

  defp operator_email?(email) when is_binary(email),
    do: email != "" and email == email |> String.trim() |> String.downcase()

  defp operator_email?(_email), do: false

  defp policy_digest(operators),
    do: Cyfr.Digest.sha256(Jason.encode!(%{version: 1, operators: operators}))

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
  narrower permission set, or an athanor scope.
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

  Uses `:tincture` authentication through the shared authorization path,
  with or without an auth provider configured.

  For an authenticated request, the caller's real `user_id` and `namespace`
  are carried through for the audit trail (namespace is identity-only and may
  be nil); a public request falls back to the tincture identity and the
  dedicated public-tincture namespace tag. The athanor is inherited from the
  caller and the context stays athanor-scoped (NOT platform-scoped) so tenant
  isolation still applies to the invocation.
  """
  @spec build_tincture_context(Context.t(), map()) :: Context.t()
  def build_tincture_context(%Context{} = caller_ctx, tincture) do
    tincture_id = Cyfr.ComponentRef.build("tincture", tincture.publisher, tincture.name)

    # Key on `authenticated` (the real signal), NOT on namespace presence — an
    # authenticated user may legitimately have a nil namespace (identity-only,
    # not required). Their namespace passes through for attribution; only a
    # genuinely public caller falls back to the public-tincture identity.
    #
    # An authenticated caller's invocation runs with the caller's OWN
    # permissions — no stronger, no weaker. A public caller gets exactly
    # [:execute] and is marked `anonymous`, which the credential plane
    # (Sanctum.VaultReader) denies: an anonymous internet request must never be
    # silently upgraded into a credential-bearing executor.
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
      # Carries the caller's resolved athanor; a nil here flows through and the
      # tenant gate rejects downstream (a tincture cannot widen tenant scope).
      athanor_id: caller_ctx.athanor_id,
      scope: :athanor,
      auth_method: :tincture,
      authenticated: true,
      anonymous: anonymous
    )
  end
end
