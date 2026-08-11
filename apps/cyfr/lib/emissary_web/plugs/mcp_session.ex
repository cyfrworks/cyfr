# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.MCPSession do
  @moduledoc """
  Authenticates an MCP request and enforces the conformance rules that must hold
  before any handler runs.

  ## Authentication

  There is no session. Every request carries its own credential and is resolved
  against the database on its own, so a revoked one stops working on the next
  call rather than whenever a cached session would have expired.

  1. `Authorization: Bearer …` — an API key or a Sanctum session token, told
     apart by the `cyfr_` prefix.
  2. A configured auth provider, for browser-borne callers.
  3. Neither — an unauthenticated context. This is not an error: the router
     gates per action and some are deliberately public.

  An auth-provider *error* is distinguished from absent credentials and fails
  closed with 503; it never degrades to unauthenticated.

  ## Conformance

  Every request declares its protocol version and client capabilities in
  `params._meta` and mirrors the routed fields into `Mcp-Method` / `Mcp-Name`.
  Header and body must agree — a header a gateway can route on is only safe if
  it cannot disagree with what the server will execute.
  """

  import Plug.Conn
  require Logger

  alias Emissary.MCP.{Protocol, Session}
  alias Sanctum.Context

  def init(opts), do: opts

  @protocol_version Emissary.MCP.Protocol.version()

  def call(conn, _opts) do
    # A bearer credential is resolved first: it authenticates the request on its
    # own, so no server-side session is involved either way.
    result_conn =
      case resolve_bearer_credential(conn) do
        {:ok, context, kind} ->
          Cyfr.LoggerContext.set_from_context(context)

          conn
          |> assign(:mcp_session, Session.ephemeral(context))
          |> assign(:mcp_context, context)
          |> assign(:auth_method, kind)

        # No credential this plug recognises. Either none was presented — the
        # public surface is reachable that way and the router gates per action —
        # or a bearer token was presented that only the auth provider could
        # claim. `presented?` distinguishes them, because the two deserve
        # different answers when nobody ends up authenticating.
        result when result in [:no_key, :unclaimed_bearer] ->
          case get_context(conn) do
            {:error, :auth_provider_error} ->
              auth_provider_error_response(conn)

            {:error, :missing_tenant} ->
              missing_tenant_error_response(conn)

            %Context{authenticated: false} when result == :unclaimed_bearer ->
              # A credential was presented, nothing claimed it, and nothing else
              # will. Serving the public surface here is a fail-open: the caller
              # gets a 200 for whatever happens to be public and never learns
              # their token is dead, which is indistinguishable from success.
              error_response(conn, :invalid_bearer)

            context ->
              Cyfr.LoggerContext.set_from_context(context)

              conn
              |> assign(:mcp_session, nil)
              |> assign(:mcp_context, context)
          end

        {:error, :missing_tenant} ->
          # API key valid but the owner has no resolved tenant/membership —
          # same 403 the session path returns.
          missing_tenant_error_response(conn)

        {:error, reason} ->
          # API key provided but invalid
          error_response(conn, reason)
      end

    # Validate MCP-Protocol-Version header for non-initialize requests
    if result_conn.halted do
      result_conn
    else
      validate_protocol_version(result_conn)
    end
  end

  # Every POST declares its protocol version twice: in `params._meta` and in the
  # `MCP-Protocol-Version` header. Both are required, and they must agree.
  #
  # The duplication is deliberate — a gateway can route and rate-limit on the
  # header without parsing the body, but only if the header cannot disagree with
  # what the server will actually execute. So a mismatch is refused outright
  # rather than resolved in favour of either side.
  #
  # Notifications are exempt: this revision defines no header requirement for
  # them, and a notification carries no id to answer an error on.
  defp validate_protocol_version(conn) do
    body = conn.body_params

    cond do
      not (is_map(body) and not is_struct(body)) ->
        conn

      is_nil(body["id"]) ->
        # A notification, not a request.
        conn

      true ->
        with %Plug.Conn{halted: false} = conn <- check_declared_version(conn, body),
             %Plug.Conn{halted: false} = conn <- check_client_capabilities(conn, body),
             %Plug.Conn{halted: false} = conn <- check_mirrored_headers(conn, body) do
          conn
        end
    end
  end

  # `clientCapabilities` is a required `_meta` field, and a missing required
  # field is `-32602`.
  #
  # It is not decoration. A stateless protocol has no handshake in which to learn
  # what the caller can do, so the server may never assume a capability the
  # request did not declare — which is what makes it safe to *offer* a client
  # something like an elicitation. Accepting requests that omit it would leave
  # the server guessing, and guessing wrong means asking a client for input it
  # has no way to supply.
  defp check_client_capabilities(conn, body) do
    case get_in(body, ["params", "_meta", Protocol.meta_client_capabilities_key()]) do
      caps when is_map(caps) ->
        assign(conn, :mcp_client_capabilities, caps)

      nil ->
        reject_version(
          conn,
          :invalid_params,
          "Missing required #{Protocol.meta_client_capabilities_key()} in params._meta."
        )

      _other ->
        reject_version(
          conn,
          :invalid_params,
          "#{Protocol.meta_client_capabilities_key()} must be an object."
        )
    end
  end

  # `Mcp-Method` and `Mcp-Name` mirror body fields into headers so an
  # intermediary can route and authorize without parsing the body. They are only
  # safe to route on if they cannot disagree with the body, so a mismatch is
  # refused here the same way a version mismatch is.
  defp check_mirrored_headers(conn, body) do
    with :ok <- match_header(conn, "mcp-method", body["method"], "Mcp-Method"),
         :ok <- match_header(conn, "mcp-name", Protocol.named_subject(body), "Mcp-Name") do
      conn
    else
      {:error, message} -> reject_version(conn, :header_mismatch, message)
    end
  end

  # A method that names no subject sends no `Mcp-Name`, and must not be
  # required to.
  defp match_header(_conn, _header, nil, _label), do: :ok

  defp match_header(conn, header, expected, label) do
    case get_req_header(conn, header) do
      [] ->
        {:error, "Missing required #{label} header."}

      [raw | _] ->
        case Protocol.decode_header_value(raw) do
          {:ok, ^expected} -> :ok
          {:ok, other} -> {:error, "#{label} header (#{other}) does not match the request body."}
          :error -> {:error, "#{label} header is not valid Base64 sentinel encoding."}
        end
    end
  end

  defp check_declared_version(conn, body) do
    header = get_req_header(conn, "mcp-protocol-version") |> List.first()
    meta = Protocol.declared_version(body)

    cond do
      is_nil(header) ->
        reject_version(
          conn,
          :header_mismatch,
          "Missing required MCP-Protocol-Version header."
        )

      is_nil(meta) ->
        reject_version(
          conn,
          :header_mismatch,
          "Missing required #{Protocol.meta_protocol_version_key()} in params._meta."
        )

      header != meta ->
        reject_version(
          conn,
          :header_mismatch,
          "MCP-Protocol-Version header (#{header}) does not match " <>
            "#{Protocol.meta_protocol_version_key()} (#{meta})."
        )

      not Protocol.supported?(header) ->
        reject_version(
          conn,
          :unsupported_protocol_version,
          "Unsupported protocol version #{header}. Supported: " <>
            Enum.join(Protocol.supported(), ", ") <> "."
        )

      true ->
        conn
    end
  end

  defp reject_version(conn, code, message) do
    conn
    |> put_resp_header("mcp-protocol-version", @protocol_version)
    |> EmissaryWeb.MCPError.halt(400, code, message)
  end

  defp missing_tenant_error_response(conn) do
    conn
    |> put_resp_header("mcp-protocol-version", @protocol_version)
    |> EmissaryWeb.MCPError.halt(
      403,
      :insufficient_permissions,
      "User has no organization membership. Contact your administrator."
    )
  end

  defp auth_provider_error_response(conn) do
    conn
    |> put_resp_header("mcp-protocol-version", @protocol_version)
    |> EmissaryWeb.MCPError.halt(503, :auth_invalid, "Authentication service unavailable")
  end

  defp get_context(conn) do
    # Get auth provider from config
    auth_provider = Application.get_env(:cyfr, :auth_provider)

    if is_nil(auth_provider) do
      # No auth configured — the operator runs without sign-in. Requests reach
      # the public surface as an unauthenticated context (no permissions, no
      # resolved org); tenant-scoped routes are rejected downstream.
      Logger.debug("[MCP Session] No auth_provider configured")
      unauthenticated_context()
    else
      # Get user from auth provider
      try do
        case auth_provider.current_user(conn) do
          nil ->
            # No credentials presented — fall through to the public surface.
            # Tenant-scoped routes are rejected downstream (no resolved org).
            Logger.debug("[MCP Session] No credentials from provider #{inspect(auth_provider)}")
            unauthenticated_context()

          {:error, reason} ->
            # An auth-provider *error* (as opposed to absent credentials) must
            # fail closed — never silently downgrade to unauthenticated.
            Logger.warning(
              "[MCP Session] Auth provider #{inspect(auth_provider)} returned error: #{inspect(reason)}"
            )

            {:error, :auth_provider_error}

          ctx ->
            # auth_provider.current_user/1 returns a Context; resolve membership and gate.
            context_from_session(ctx)
        end
      rescue
        e ->
          Logger.error(
            "[MCP Session] Auth provider #{inspect(auth_provider)} raised: #{Exception.message(e)}"
          )

          # Auth provider crash is a server error — fail the request rather than
          # silently downgrading to unauthenticated (which would bypass all authz).
          {:error, :auth_provider_error}
      end
    end
  end

  defp unauthenticated_context do
    Context.build(
      user_id: nil,
      org_id: nil,
      permissions: [],
      scope: :project,
      auth_method: nil,
      authenticated: false
    )
  end

  # A pre-claim / unauthenticated context (valid session, namespace not yet
  # claimed) legitimately carries no resolved org — it is forwarded to the
  # namespace-claim flow downstream, not tenant-gated here.
  defp context_from_session(%Context{authenticated: false} = ctx), do: ensure_namespace(ctx)

  defp context_from_session(%Context{} = ctx) do
    ctx =
      ctx
      |> Sanctum.Tenancy.resolve_into()
      |> ensure_namespace()

    case Context.tenant_ok(ctx) do
      {:error, :missing_tenant} ->
        Logger.warning(
          "[MCPSession] Authenticated user #{ctx.user_id} has no resolved org_id — rejecting"
        )

        {:error, :missing_tenant}

      :ok ->
        ctx
    end
  end

  # Belt-and-suspenders: Session.load/row_to_context already populates
  # ctx.namespace via Sanctum.Namespace.lookup/1, but if a Context arrives
  # here from a path that didn't go through Session.load (e.g. auth_provider
  # synthesizing a fresh Context), refresh from CredentialStore.
  defp ensure_namespace(%Context{namespace: ns} = ctx) when is_binary(ns) and ns != "", do: ctx

  defp ensure_namespace(%Context{} = ctx),
    do: %{ctx | namespace: Sanctum.Namespace.lookup(ctx.user_id)}

  # ============================================================================
  # API Key Authentication
  # ============================================================================

  @doc false
  # Resolve a credential presented in the `Authorization: Bearer` header.
  #
  # Two credential kinds share the header and are told apart by the `cyfr_`
  # prefix: an API key, or a Sanctum session token. Both resolve to a Context
  # on the request itself, consulting the database every time — no server-side
  # session state, and no cached copy that can outlive a logout.
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

  # A Sanctum session token presented as a bearer credential. `Session.load/2`
  # reads the row, so a revoked or expired session is rejected on the very next
  # request rather than surviving in a cache.
  defp validate_session_token(token) do
    case Sanctum.Session.load(token, surface: :console) do
      {:ok, ctx} ->
        case context_from_session(ctx) do
          {:error, :missing_tenant} -> {:error, :missing_tenant}
          %Context{} = resolved -> {:ok, resolved, :session_token}
        end

      {:error, :namespace_unavailable} ->
        # Transient store failure during session→context resolution, distinct
        # from an unknown session. Retryable, so it must not read as "expired".
        {:error, :auth_provider_error}

      {:error, _reason} ->
        # Not a session token this server issued — but not necessarily invalid.
        # A configured auth provider may accept bearer tokens of its own (an
        # OIDC access token, say), and it reads the header itself. So this falls
        # through rather than deciding, and the caller in `call/2` refuses only
        # once the provider has also declined.
        :unclaimed_bearer
    end
  end

  # Validate an API key and build a project-scoped context from the key row.
  #
  # API keys are PROJECT credentials: org_id/project_id come from the stored
  # key (Sanctum.ApiKey.context_from_metadata/1) — never from the request or
  # the creating user's *current* membership. Key validity is independent of
  # the creator's membership; revocation is the control. When an auth provider
  # is configured, an org-less key is rejected via the configured tenant
  # policy's require_org/1 (the same gate context_from_session/1 applies);
  # no-op for single-user installs.
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

      {:error, :ip_not_allowed} ->
        {:error, :ip_not_allowed}

      {:error, reason} ->
        Logger.warning("[MCP Session] API key validation failed: #{inspect(reason)}")
        {:error, :api_key_validation_failed}
    end
  end

  # Error response for API key validation failures
  defp error_response(conn, :invalid_bearer) do
    conn
    |> put_resp_header("mcp-protocol-version", @protocol_version)
    |> EmissaryWeb.MCPError.halt(
      401,
      :auth_invalid,
      "The presented credential is not valid. If it expired, sign in again."
    )
  end

  defp error_response(conn, :invalid_api_key) do
    conn
    |> put_resp_header("mcp-protocol-version", @protocol_version)
    |> EmissaryWeb.MCPError.halt(401, :auth_invalid, "Invalid API key")
  end

  defp error_response(conn, :api_key_revoked) do
    conn
    |> put_resp_header("mcp-protocol-version", @protocol_version)
    |> EmissaryWeb.MCPError.halt(401, :auth_invalid, "API key has been revoked")
  end

  defp error_response(conn, :ip_not_allowed) do
    conn
    |> put_resp_header("mcp-protocol-version", @protocol_version)
    |> EmissaryWeb.MCPError.halt(
      403,
      :insufficient_permissions,
      "Request IP not in API key allowlist"
    )
  end

  defp error_response(conn, _reason) do
    conn
    |> put_resp_header("mcp-protocol-version", @protocol_version)
    |> EmissaryWeb.MCPError.halt(401, :auth_invalid, "API key validation failed")
  end
end
