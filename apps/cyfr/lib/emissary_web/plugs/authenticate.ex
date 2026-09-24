# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.Authenticate do
  @moduledoc """
  Resolves the caller's `%Sanctum.Context{}` and assigns it as `:context`.

  There is no server-side session state beyond the session row. Every request
  carries its own credential; resolution goes through `Sanctum.Caller`, whose
  short established-context memo is invalidated by every session mutation, so
  a revoked credential stops working on the next call.

  1. `Authorization: Bearer …` — an API key or a Sanctum session token, told
     apart by the `cyfr_` prefix.
  2. A configured auth provider, for browser-borne callers.
  3. Neither — an unauthenticated context. This is not an error: the surface
     behind this plug gates per action and some are deliberately public.

  An auth-provider *error* is distinguished from absent credentials and fails
  closed with 503; it never degrades to unauthenticated.

  ## Options

  - `:errors` — rejection renderer, defaulting to `EmissaryWeb.MCPError`.
    Use `EmissaryWeb.ApiError` for ordinary authenticated HTTP routes.

  This plug carries no protocol knowledge. The MCP endpoint's own conformance
  rules — the per-request `_meta`, the mirrored headers — live in
  `EmissaryWeb.Plugs.MCPRequestMetadata`, which runs after it.
  """

  import Plug.Conn
  require Logger

  alias Sanctum.Context

  # `init/1` normalizes and `call/2` re-reads with the same default, so the plug
  # behaves identically whether it is mounted in a pipeline or called directly.
  @default_errors EmissaryWeb.MCPError

  def init(opts), do: Keyword.put_new(opts, :errors, @default_errors)

  def call(conn, opts) do
    errors = Keyword.get(opts, :errors, @default_errors)

    # A bearer credential is resolved first: it authenticates the request on its
    # own, so no server-side session is involved either way.
    case resolve_bearer_credential(conn) do
      {:ok, context, kind} ->
        Prima.LoggerContext.set_from_context(context)

        conn
        |> assign(:context, stamp_client_ip(conn, context))
        |> assign(:auth_method, kind)

      # No credential this plug recognises. Either none was presented — the
      # public surface is reachable that way and the router gates per action —
      # or a bearer token was presented that only the auth provider could
      # claim. The two deserve different answers when nobody ends up
      # authenticating, which is what the `result` match below distinguishes.
      result when result in [:no_key, :unclaimed_bearer] ->
        case get_context(conn) do
          {:error, :auth_provider_error} ->
            auth_provider_error_response(conn, errors)

          {:error, :missing_tenant} ->
            missing_tenant_error_response(conn, errors)

          %Context{authenticated: false, user_id: nil} when result == :unclaimed_bearer ->
            # A credential was presented, nothing claimed it, and nothing else
            # will. Serving the public surface here is a fail-open: the caller
            # gets a 200 for whatever happens to be public and never learns
            # their token is dead, which is indistinguishable from success.
            #
            # `user_id: nil` is the discriminator: a provider bearer that DID
            # identify someone who is door-denied yields an unauthenticated
            # context WITH identity fields, and
            # `context_from_session/1` documents that shape as forwarded, not
            # halted — the same person's session token already forwards it.
            error_response(conn, :invalid_bearer, errors)

          context ->
            context = stamp_client_ip(conn, context)
            Prima.LoggerContext.set_from_context(context)
            assign(conn, :context, context)
        end

      {:error, :missing_tenant} ->
        # API key valid but the owner has no resolved tenant/membership.
        missing_tenant_error_response(conn, errors)

      {:error, :auth_provider_error} ->
        # The key store could not answer: a 503, never a 401 — the
        # credential was not judged.
        auth_provider_error_response(conn, errors)

      {:error, reason} ->
        # API key provided but invalid
        error_response(conn, reason, errors)
    end
  end

  defp missing_tenant_error_response(conn, errors) do
    reason = {:missing_tenant, :no_membership}
    errors.halt(conn, 403, reason, Sanctum.Unauthorized.message(reason))
  end

  # The store could not judge the credential: unavailable, never a
  # verdict on it.
  defp auth_provider_error_response(conn, errors) do
    errors.halt(conn, 503, :auth_provider_error, "Authentication service unavailable")
  end

  defp get_context(conn) do
    auth_provider = Cyfr.RuntimeConfig.auth_provider()

    if is_nil(auth_provider) do
      # No auth configured — the operator runs without sign-in. Requests reach
      # the public surface as an unauthenticated context (no permissions, no
      # resolved athanor); tenant-scoped routes are rejected downstream.
      Logger.debug("[Authenticate] No auth_provider configured")
      unauthenticated_context()
    else
      try do
        case auth_provider.current_user(conn) do
          nil ->
            # No credentials presented — fall through to the public surface.
            # Tenant-scoped routes are rejected downstream (no resolved athanor).
            Logger.debug("[Authenticate] No credentials from provider #{inspect(auth_provider)}")
            unauthenticated_context()

          {:error, reason} ->
            # An auth-provider *error* (as opposed to absent credentials) must
            # fail closed — never silently downgrade to unauthenticated.
            Logger.warning(
              "[Authenticate] Auth provider #{inspect(auth_provider)} returned error: #{inspect(reason)}"
            )

            {:error, :auth_provider_error}

          ctx ->
            # current_user/1 returns a Context; resolve membership and gate.
            context_from_session(ctx)
        end
      rescue
        e ->
          Logger.error(
            "[Authenticate] Auth provider #{inspect(auth_provider)} raised: #{Exception.message(e)}"
          )

          # An auth provider crash is a server error — fail the request rather
          # than silently downgrading to unauthenticated (which would bypass
          # all authz).
          {:error, :auth_provider_error}
      end
    end
  end

  # The caller's address, carried on the context so an ANONYMOUS action can
  # charge a per-address budget without a conn. `Sanctum.Providers.Session`'s
  # device flows are the case: they are `auth: :anonymous` and reached only
  # over `/mcp`, where the transport meters all methods together — so
  # several addresses could still exhaust the global sign-in ceiling
  # between them while none tripped the shared bucket.
  #
  # Not identity, and it authorizes nothing. `Sanctum.ClientIp.resolve/1`
  # is the same trust boundary every limiter uses.
  defp stamp_client_ip(conn, %Context{} = context) do
    %{context | client_ip: Sanctum.ClientIp.resolve(conn)}
  end

  defp unauthenticated_context do
    Context.build(
      user_id: nil,
      athanor_id: nil,
      permissions: [],
      scope: :athanor,
      auth_method: nil,
      authenticated: false
    )
  end

  # `Sanctum.Caller` owns the establish recipe; this surface's mapping: a
  # door-denied context is forwarded rather than halted — it reaches only
  # the anonymous surface, which needs its fields to say who was refused.
  defp context_from_session(%Context{} = ctx) do
    case Sanctum.Caller.establish_context(ctx) do
      {:ok, established} ->
        established

      {:error, {:denied, denied}} ->
        denied

      {:error, :no_athanor} ->
        Logger.warning(
          "[Authenticate] Authenticated user #{ctx.user_id} has no resolved athanor — rejecting"
        )

        {:error, :missing_tenant}

      # The membership read failed. That is not "you have no athanor" — it is
      # "we could not find out", and answering 403 tells the person to ask an
      # operator about a fault an operator cannot see. Same answer the session
      # path already gives for the same underlying failure.
      {:error, :unavailable} ->
        Logger.error("[Authenticate] membership read failed for #{ctx.user_id} — answering 503")

        {:error, :auth_provider_error}
    end
  end

  # ============================================================================
  # Bearer credentials
  # ============================================================================

  # Two credential kinds share the header and are told apart by the `cyfr_`
  # prefix: an API key, or a Sanctum session token. Both resolve to a Context
  # on the request itself; the session path rides `Sanctum.Caller`'s short
  # memo, which every logout/revocation invalidates, so no cached copy
  # outlives one.
  #
  # Returns {:ok, context, :api_key | :session_token}, :no_key when no bearer
  # credential is present, or {:error, reason}.
  defp resolve_bearer_credential(conn) do
    case Sanctum.BearerToken.read(conn) do
      nil ->
        :no_key

      token ->
        if Sanctum.ApiKey.looks_like_key?(token) do
          with {:ok, ctx} <- validate_api_key(conn, token), do: {:ok, ctx, :api_key}
        else
          with {:ok, ctx, kind} <- validate_session_token(token), do: {:ok, ctx, kind}
        end
    end
  end

  # A Sanctum session token presented as a bearer credential.
  # `Caller.establish/2` reads the row through a short memo that every
  # session mutation invalidates; the memo bounds establishing, not
  # validating, so the context it answers is then revalidated against the
  # stored session and standing (`Caller.revalidate_session/1`) before it
  # admits anything — a revocation this member never heard of refuses here.
  defp validate_session_token(token) do
    # This surface never slides the session — the console hooks do.
    # The context arrives carrying its session row key and the binding that
    # names it (`Sanctum.Session`, the one place both are stamped).
    case establish_session(token) do
      {:ok, ctx} ->
        {:ok, ctx, :session_token}

      {:error, {:denied, denied}} ->
        # No standing at the door: only the anonymous surface answers.
        {:ok, denied, :session_token}

      {:error, :no_athanor} ->
        {:error, :missing_tenant}

      {:error, :unavailable} ->
        # Transient store failure during session→context resolution, distinct
        # from an unknown session. Retryable, so it must not read as "expired".
        {:error, :auth_provider_error}

      {:error, :unauthenticated} ->
        # Not a session token this server issued — but not necessarily invalid.
        # A configured auth provider may accept bearer tokens of its own (an
        # OIDC access token, say), and it reads the header itself. So this falls
        # through rather than deciding, and the caller in `call/2` refuses only
        # once the provider has also declined.
        :unclaimed_bearer
    end
  end

  defp establish_session(token, retried? \\ false) do
    with {:ok, ctx} <- Sanctum.Caller.establish(token, refresh: false) do
      case Sanctum.Caller.revalidate_session(ctx) do
        {:ok, fresh} ->
          {:ok, fresh}

        {:error, :unavailable} ->
          {:error, :unavailable}

        # The memo named an estate the session no longer reaches: this
        # member's copy is stale, and one establish without it resolves
        # the session's standing estate again.
        {:error, :not_member} when not retried? ->
          Sanctum.Caller.drop_memo(ctx.session_token_hash)
          establish_session(token, true)

        # Gone, expired or retired since the memo was filled: no longer a
        # session this server stands behind.
        {:error, _refused} ->
          {:error, :unauthenticated}
      end
    end
  end

  # Validate an API key and build an athanor-scoped context from the key row.
  #
  # API keys are ATHANOR credentials: the athanor comes from the stored key
  # (Sanctum.ApiKey.context_from_metadata/1) — never from the request or the
  # creating user's *current* membership. Key validity is independent of the
  # creator's membership; revocation is the control. An athanor-less key is
  # rejected by the tenant gate (the same gate context_from_session/1
  # applies).
  # The one recipe establishes the key; this surface maps its refusals to
  # the wire. An archived athanor or a denied creator answers exactly like
  # a revoked key, so nothing about either leaks.
  defp validate_api_key(conn, key) do
    case Sanctum.Caller.establish({:api_key, key}, client_ip: Sanctum.ClientIp.resolve(conn)) do
      {:ok, ctx} -> {:ok, ctx}
      {:error, :no_athanor} -> {:error, :missing_tenant}
      {:error, :invalid_credential} -> {:error, :invalid_api_key}
      {:error, :revoked} -> {:error, :api_key_revoked}
      {:error, :ip_not_allowed} -> {:error, :ip_not_allowed}
      {:error, :unavailable} -> {:error, :auth_provider_error}
    end
  end

  # Each refusal renders with its own sentence (`Prima.Refusal`).
  defp error_response(conn, :invalid_bearer, errors),
    do: errors.halt(conn, 401, :invalid_bearer, nil)

  defp error_response(conn, :invalid_api_key, errors),
    do: errors.halt(conn, 401, :invalid_api_key, nil)

  defp error_response(conn, :api_key_revoked, errors),
    do: errors.halt(conn, 401, :api_key_revoked, nil)

  defp error_response(conn, :ip_not_allowed, errors),
    do: errors.halt(conn, 403, :ip_not_allowed, nil)
end
