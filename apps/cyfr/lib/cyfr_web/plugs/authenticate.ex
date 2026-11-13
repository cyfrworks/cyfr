# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.Authenticate do
  @moduledoc """
  Resolves the caller's `%Sanctum.Context{}` and assigns it as `:context`.

  There is no server-side session state beyond the session row. Every request
  carries its own credential; resolution goes through `Sanctum.Caller`, whose
  short established-context memo is invalidated by every session mutation, so
  a revoked credential stops working on the next call.

  1. `Authorization: Bearer …` — an API key or a Sanctum session token, told
     apart by the `cyfr_` prefix. A bearer that is neither is refused with
     401, never served as an anonymous caller.
  2. None — an unauthenticated context. This is not an error: the surface
     behind this plug gates per action and some are deliberately public.

  A store that cannot judge the credential is distinguished from a refused
  one and fails closed with 503; it never degrades to unauthenticated. So
  does a session of a remote person whose identity could not be confirmed
  fresh
  (`:identity_stale`): it answers 503 with that refusal's class and
  sentence, and the session stands. A person who stands but for the
  company sign-in this CYFR requires (`:company_login_required`), by a
  session or by an API key they made, is answered 403 with that
  refusal's sentence: they sign in with their company in a browser.

  Every context this plug assigns carries the origin `programmatic`
  (`Prima.Origin`): the HTTP API and MCP are programmatic surfaces,
  whichever credential the request carries.

  ## Options

  - `:errors` — rejection renderer, defaulting to `CyfrWeb.ApiError`. A
    JSON-RPC route passes its own renderer.

  This plug carries no protocol knowledge. The MCP endpoint's own conformance
  rules — the per-request `_meta`, the mirrored headers — live in
  `Emissary.Web.Plugs.MCPRequestMetadata`, which runs after it.
  """

  import Plug.Conn

  alias Sanctum.Context

  @default_errors CyfrWeb.ApiError

  def init(opts), do: Keyword.put_new(opts, :errors, @default_errors)

  def call(conn, opts) do
    errors = Keyword.fetch!(opts, :errors)

    # A bearer credential is resolved first: it authenticates the request on its
    # own, so no server-side session is involved either way.
    case resolve_bearer_credential(conn) do
      {:ok, context} ->
        Prima.LoggerContext.set_from_context(context)
        assign(conn, :context, established(conn, context))

      # No credential at all: the public surface is reachable that way, and
      # the router gates per action.
      :no_key ->
        context = established(conn, unauthenticated_context())
        Prima.LoggerContext.set_from_context(context)
        assign(conn, :context, context)

      {:error, :missing_tenant} ->
        # A credential that stands, whose person has no athanor to work in.
        missing_tenant_error_response(conn, errors)

      {:error, :auth_provider_error} ->
        # The store could not answer: a 503, never a 401 — the
        # credential was not judged.
        auth_provider_error_response(conn, errors)

      {:error, reason} ->
        # A credential presented and refused.
        error_response(conn, reason, errors)
    end
  end

  defp missing_tenant_error_response(conn, errors) do
    reason = {:missing_tenant, :no_athanor}
    errors.halt(conn, 403, reason, Sanctum.Unauthorized.message(reason))
  end

  # The store could not judge the credential: unavailable, never a
  # verdict on it.
  defp auth_provider_error_response(conn, errors) do
    errors.halt(conn, 503, :auth_provider_error, "Authentication service unavailable")
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

  # The context as the surface hands it on: the caller's address, the
  # request's identity the pipeline minted (`CyfrWeb.Plugs.CallIdentity`)
  # — its request id and the admission's call id, which the gate takes as
  # its own — and the origin of this admission path. A call over the HTTP
  # API or MCP is `programmatic` whatever credential it carries: a key, a
  # session token or none proves who is calling, never that a person is
  # present.
  defp established(conn, %Context{} = context) do
    stamped = CyfrWeb.Plugs.CallIdentity.stamp(conn, stamp_client_ip(conn, context))
    %{stamped | origin: :programmatic}
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

  # ============================================================================
  # Bearer credentials
  # ============================================================================

  # Two credential kinds share the header and are told apart by the `cyfr_`
  # prefix: an API key, or a Sanctum session token. Both resolve to a Context
  # on the request itself; the session path rides `Sanctum.Caller`'s short
  # memo, which every logout/revocation invalidates, so no cached copy
  # outlives one.
  #
  # Returns {:ok, context}, whose `auth_method` names the credential's kind,
  # :no_key when no bearer credential is present, or {:error, reason}.
  defp resolve_bearer_credential(conn) do
    case Sanctum.BearerToken.read(conn) do
      nil ->
        :no_key

      token ->
        if Sanctum.ApiKey.looks_like_key?(token),
          do: validate_api_key(conn, token),
          else: validate_session_token(token)
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
        {:ok, ctx}

      {:error, {:denied, denied}} ->
        # No standing at the door: only the anonymous surface answers.
        {:ok, denied}

      {:error, :no_athanor} ->
        {:error, :missing_tenant}

      {:error, :unavailable} ->
        # Transient store failure during session→context resolution, distinct
        # from an unknown session. Retryable, so it must not read as "expired".
        {:error, :auth_provider_error}

      {:error, :identity_stale} ->
        # A remote person's identity could not be confirmed fresh: their
        # work pauses and the session stands, so it reads as neither
        # "expired" nor a denial.
        {:error, :identity_stale}

      {:error, :identity_gone} ->
        # The person's account is gone at its directory: a denial for
        # good, in its own sentence, never an expired session.
        {:error, :identity_gone}

      {:error, :company_login_required} ->
        {:error, :company_login_required}

      {:error, :unauthenticated} ->
        # Not a session this server issued, or one no longer standing.
        # Serving the public surface here would be a fail-open: the caller
        # would get a 200 for whatever happens to be public and never learn
        # their token is dead.
        {:error, :invalid_bearer}
    end
  end

  defp establish_session(token, retried? \\ false) do
    with {:ok, ctx} <- Sanctum.Caller.establish(token, refresh: false) do
      case Sanctum.Caller.revalidate_session(ctx) do
        {:ok, fresh} ->
          {:ok, fresh}

        {:error, reason}
        when reason in [:unavailable, :identity_stale, :identity_gone, :company_login_required] ->
          {:error, reason}

        # The memo named an athanor the session no longer reaches: this
        # member's copy is stale, and one establish without it resolves
        # the session's standing athanor again.
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
  # creating user's *current* standing. Revocation is the control. An athanor-less key is
  # rejected by the tenant gate (`Sanctum.Caller`'s, as for a session).
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
      {:error, :company_login_required} -> {:error, :company_login_required}
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

  # A paused identity: the refusal's class (`unavailable`) and sentence,
  # retryable, never a 401 that reads as a dead credential.
  defp error_response(conn, :identity_stale, errors),
    do: errors.halt(conn, 503, :identity_stale, nil)

  defp error_response(conn, :company_login_required, errors),
    do: errors.halt(conn, 403, :company_login_required, nil)

  # An account gone: the refusal's class (`forbidden`) and sentence.
  defp error_response(conn, :identity_gone, errors),
    do: errors.halt(conn, 403, :identity_gone, nil)
end
