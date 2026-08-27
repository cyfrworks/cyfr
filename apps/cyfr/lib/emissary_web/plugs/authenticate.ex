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

  - `:errors` — the module that renders a rejection, defaulting to
    `EmissaryWeb.MCPError`. `EmissaryWeb.ApiError` is the plain-HTTP
    counterpart. This is the only thing that differs between the MCP endpoint
    and an ordinary authenticated route, which is why it is a parameter rather
    than a second copy of the credential logic.

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
        Cyfr.LoggerContext.set_from_context(context)

        conn
        |> assign(:context, context)
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

          %Context{authenticated: false} when result == :unclaimed_bearer ->
            # A credential was presented, nothing claimed it, and nothing else
            # will. Serving the public surface here is a fail-open: the caller
            # gets a 200 for whatever happens to be public and never learns
            # their token is dead, which is indistinguishable from success.
            error_response(conn, :invalid_bearer, errors)

          context ->
            Cyfr.LoggerContext.set_from_context(context)
            assign(conn, :context, context)
        end

      {:error, :missing_tenant} ->
        # API key valid but the owner has no resolved tenant/membership.
        missing_tenant_error_response(conn, errors)

      {:error, reason} ->
        # API key provided but invalid
        error_response(conn, reason, errors)
    end
  end

  defp missing_tenant_error_response(conn, errors) do
    errors.halt(
      conn,
      403,
      :insufficient_permissions,
      "User has no athanor. Contact your administrator."
    )
  end

  defp auth_provider_error_response(conn, errors) do
    errors.halt(conn, 503, :auth_invalid, "Authentication service unavailable")
  end

  defp get_context(conn) do
    auth_provider = Application.get_env(:cyfr, :auth_provider)

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
  # pre-claim or door-denied context is forwarded rather than halted — it
  # reaches only the anonymous surface, and the claim flow downstream
  # needs its fields.
  defp context_from_session(%Context{} = ctx) do
    case Sanctum.Caller.establish_context(ctx) do
      {:ok, established} ->
        established

      {:error, {:claim_pending, pre_claim}} ->
        pre_claim

      {:error, {:denied, denied}} ->
        denied

      {:error, :no_athanor} ->
        Logger.warning(
          "[Authenticate] Authenticated user #{ctx.user_id} has no resolved athanor — rejecting"
        )

        {:error, :missing_tenant}
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
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when token != "" ->
        if Sanctum.ApiKey.looks_like_key?(token) do
          with {:ok, ctx} <- validate_api_key(conn, token), do: {:ok, ctx, :api_key}
        else
          with {:ok, ctx, kind} <- validate_session_token(token), do: {:ok, ctx, kind}
        end

      _ ->
        :no_key
    end
  end

  # A Sanctum session token presented as a bearer credential.
  # `Caller.establish/2` reads the row (through a short memo that every
  # session mutation invalidates), so a revoked or expired session is
  # rejected on the very next request.
  defp validate_session_token(token) do
    # This surface never slides the session — the console hooks do.
    case Sanctum.Caller.establish(token, refresh: false) do
      {:ok, ctx} ->
        {:ok, stamp_token_hash(ctx, token), :session_token}

      {:error, {:claim_pending, pre_claim}} ->
        # Forwarded to the claim flow downstream, not tenant-gated here.
        {:ok, stamp_token_hash(pre_claim, token), :session_token}

      {:error, {:denied, denied}} ->
        # No standing at the door: only the anonymous surface answers.
        {:ok, stamp_token_hash(denied, token), :session_token}

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

  # The row key, not the token: enough for the caller to retire its own
  # session, useless for authenticating as it.
  defp stamp_token_hash(%Context{} = ctx, token),
    do: %{ctx | session_token_hash: Sanctum.Session.token_hash(token)}

  # Validate an API key and build an athanor-scoped context from the key row.
  #
  # API keys are ATHANOR credentials: the athanor comes from the stored key
  # (Sanctum.ApiKey.context_from_metadata/1) — never from the request or the
  # creating user's *current* membership. Key validity is independent of the
  # creator's membership; revocation is the control. An athanor-less key is
  # rejected by the tenant gate (the same gate context_from_session/1
  # applies).
  defp validate_api_key(conn, key) do
    client_ip = Sanctum.ClientIp.resolve(conn)

    case Sanctum.ApiKey.validate(key, client_ip: client_ip) do
      {:ok, metadata} ->
        ctx = Sanctum.ApiKey.context_from_metadata(metadata)

        case Context.tenant_ok(ctx) do
          :ok -> {:ok, ctx}
          {:error, :missing_tenant} -> {:error, :missing_tenant}
        end

      {:error, :invalid_key} ->
        {:error, :invalid_api_key}

      {:error, :revoked} ->
        {:error, :api_key_revoked}

      # The athanor is archived or the creator is denied on this server —
      # answered exactly like a revoked key, so nothing about either leaks.
      {:error, :channel_closed} ->
        {:error, :api_key_revoked}

      {:error, :ip_not_allowed} ->
        {:error, :ip_not_allowed}

      {:error, reason} ->
        Logger.warning("[Authenticate] API key validation failed: #{inspect(reason)}")
        {:error, :api_key_validation_failed}
    end
  end

  defp error_response(conn, :invalid_bearer, errors) do
    errors.halt(
      conn,
      401,
      :auth_invalid,
      "The presented credential is not valid. If it expired, sign in again."
    )
  end

  defp error_response(conn, :invalid_api_key, errors),
    do: errors.halt(conn, 401, :auth_invalid, "Invalid API key")

  defp error_response(conn, :api_key_revoked, errors),
    do: errors.halt(conn, 401, :auth_invalid, "API key has been revoked")

  defp error_response(conn, :ip_not_allowed, errors),
    do: errors.halt(conn, 403, :insufficient_permissions, "Request IP not in API key allowlist")

  defp error_response(conn, _reason, errors),
    do: errors.halt(conn, 401, :auth_invalid, "API key validation failed")
end
