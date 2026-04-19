defmodule EmissaryWeb.Plugs.MCPSession do
  @moduledoc """
  Plug for MCP session validation and context injection.

  Handles:
  - Extracting Mcp-Session-Id header
  - Validating existing sessions
  - Creating context for new sessions (initialization)
  - Authentication via configured auth provider
  - API key authentication via Bearer token

  ## Authentication Priority

  1. API Key (Bearer token with cyfr_ prefix) - stateless, no session required
  2. Session ID (Mcp-Session-Id header) - stateful, requires prior initialization
  3. Auth Provider (OAuth, OIDC, etc.) - for session initialization

  ## Session Flow

  1. First request (initialize): No session ID, creates new session
  2. Subsequent requests: Validates session ID, loads session
  3. Invalid session ID: Returns 404 Not Found

  ## API Key Flow

  API keys bypass session management entirely. Each request is authenticated
  independently via the Bearer token.
  """

  import Plug.Conn
  require Logger

  alias Emissary.MCP.{Message, Session}
  alias Sanctum.Context

  def init(opts), do: opts

  @protocol_version "2025-11-25"

  def call(conn, _opts) do
    # Check API key first - this is stateless auth that bypasses sessions
    result_conn =
      case extract_and_validate_api_key(conn) do
        {:ok, context} ->
          # API key auth successful - no session needed
          Cyfr.LoggerContext.set_from_context(context)

          conn
          |> assign(:mcp_session, nil)
          |> assign(:mcp_context, context)
          |> assign(:auth_method, :api_key)

        :no_key ->
          # No API key - fall back to session-based auth
          handle_session_auth(conn)

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

  # Validate MCP-Protocol-Version header.
  # Skip for initialize requests (which establish the version).
  # Reject missing or mismatched header for all other requests.
  defp validate_protocol_version(conn) do
    is_initialize =
      is_map(conn.body_params) and not is_struct(conn.body_params) and
        conn.body_params["method"] == "initialize"

    if is_initialize do
      conn
    else
      case get_req_header(conn, "mcp-protocol-version") do
        [@protocol_version] ->
          conn

        [invalid_version] ->
          conn
          |> put_resp_header("mcp-protocol-version", @protocol_version)
          |> put_status(400)
          |> Phoenix.Controller.json(%{
            "jsonrpc" => "2.0",
            "error" => %{
              "code" => Message.cyfr_code(:invalid_protocol),
              "message" =>
                "Unsupported MCP-Protocol-Version: #{invalid_version}. Server supports: #{@protocol_version}"
            },
            "id" => nil
          })
          |> halt()

        [] ->
          # MCP spec: for backwards compatibility, if no header is sent,
          # assume 2025-11-25. Also allow if session already negotiated the version.
          if conn.assigns[:mcp_session] != nil do
            # Session exists — version was already negotiated during initialize
            conn
          else
            # No session and no header — assume backwards-compat version per spec
            # (This allows pre-2025-11-25 clients to function)
            conn
          end
      end
    end
  end

  # Session-based authentication flow
  defp handle_session_auth(conn) do
    session_id = get_session_id(conn)

    case get_context(conn) do
      {:error, :auth_provider_error} ->
        auth_provider_error_response(conn)

      {:error, :missing_tenant} ->
        missing_tenant_error_response(conn)

      context ->
        do_handle_session_auth(conn, session_id, context)
    end
  end

  defp do_handle_session_auth(conn, session_id, context) do
    cond do
      # Has valid session ID
      session_id && Session.exists?(session_id) ->
        {:ok, session} = Session.get(session_id)

        case get_context(conn) do
          {:error, :auth_provider_error} ->
            auth_provider_error_response(conn)

          {:error, :missing_tenant} ->
            missing_tenant_error_response(conn)

          fresh_context ->
            if tenant_changed?(session.context, fresh_context) do
              Session.invalidate_on_context_change(session_id, "tenant_changed")
              {:ok, new_session} = Session.create(fresh_context, session.capabilities)
              Cyfr.LoggerContext.set_from_context(fresh_context)

              conn
              |> put_resp_header("mcp-session-id", new_session.id)
              |> assign(:mcp_session, new_session)
              |> assign(:mcp_context, fresh_context)
            else
              # Async refresh SQLite expiration (activity-based TTL).
              refresh_token = session.sanctum_token || session_id
              logger_metadata = Cyfr.LoggerContext.capture()

              case Task.Supervisor.start_child(Emissary.TaskSupervisor, fn ->
                     Cyfr.LoggerContext.restore(logger_metadata)
                     Sanctum.Session.refresh(refresh_token)
                   end) do
                {:ok, _pid} ->
                  :ok

                {:error, reason} ->
                  Logger.debug(
                    "[MCPSession] Failed to start session refresh task: #{inspect(reason)}"
                  )
              end

              Cyfr.LoggerContext.set_from_context(session.context)

              conn
              |> assign(:mcp_session, session)
              |> assign(:mcp_context, session.context)
            end
        end

      # Has session ID but it's invalid/expired (in memory)
      session_id ->
        # Try to hydrate from persistent storage before returning error
        case Sanctum.Session.get_user(session_id) do
          {:ok, user} ->
            case context_from_user(user) do
              {:error, :missing_tenant} ->
                missing_tenant_error_response(conn)

              context ->
                {:ok, session} = Session.hydrate(session_id, context)
                # Extend session expiration on successful hydration (activity-based TTL)
                _ = Sanctum.Session.refresh(session_id)
                Cyfr.LoggerContext.set_from_context(session.context)

                conn
                |> assign(:mcp_session, session)
                |> assign(:mcp_context, session.context)
            end

          _ ->
            # Allow initialize requests through — the client may be re-initializing
            # with a stale session ID cached from a previous server lifecycle.
            # Guard: body_params may be %Plug.Conn.Unfetched{} in tests or if
            # Plug.Parsers hasn't run yet, so check it's a map first.
            if is_map(conn.body_params) and not is_struct(conn.body_params) and
                 conn.body_params["method"] == "initialize" do
              case get_context(conn) do
                {:error, :auth_provider_error} ->
                  auth_provider_error_response(conn)

                {:error, :missing_tenant} ->
                  missing_tenant_error_response(conn)

                init_context ->
                  Cyfr.LoggerContext.set_from_context(init_context)

                  conn
                  |> assign(:mcp_session, nil)
                  |> assign(:mcp_context, init_context)
              end
            else
              conn
              |> put_resp_header("mcp-protocol-version", @protocol_version)
              |> put_status(404)
              |> Phoenix.Controller.json(%{
                "jsonrpc" => "2.0",
                "error" => %{
                  "code" => Message.cyfr_code(:session_expired),
                  "message" => "Session not found or expired"
                },
                "id" => nil
              })
              |> halt()
            end
        end

      # No session ID - unauthenticated
      true ->
        Cyfr.LoggerContext.set_from_context(context)

        conn
        |> assign(:mcp_session, nil)
        |> assign(:mcp_context, context)
    end
  end

  defp missing_tenant_error_response(conn) do
    conn
    |> put_resp_header("mcp-protocol-version", @protocol_version)
    |> put_status(403)
    |> Phoenix.Controller.json(%{
      "jsonrpc" => "2.0",
      "error" => %{
        "code" => Message.cyfr_code(:insufficient_permissions),
        "message" => "User has no organization membership. Contact your administrator."
      },
      "id" => nil
    })
    |> halt()
  end

  defp auth_provider_error_response(conn) do
    conn
    |> put_resp_header("mcp-protocol-version", @protocol_version)
    |> put_status(503)
    |> Phoenix.Controller.json(%{
      "jsonrpc" => "2.0",
      "error" => %{
        "code" => Message.cyfr_code(:auth_invalid),
        "message" => "Authentication service unavailable"
      },
      "id" => nil
    })
    |> halt()
  end

  defp get_session_id(conn) do
    case get_req_header(conn, "mcp-session-id") do
      [id | _] -> id
      [] -> nil
    end
  end

  defp get_context(conn) do
    # Get auth provider from config
    auth_provider = Application.get_env(:cyfr, :auth_provider)

    arx? = Code.ensure_loaded?(SanctumArx.License) and SanctumArx.License.edition() == :arx

    if is_nil(auth_provider) do
      if arx? do
        Logger.error(
          "[MCP Session] SECURITY: No auth_provider configured in Arx mode. " <>
            "Rejecting request — unauthenticated context not permitted."
        )

        {:error, :auth_provider_error}
      else
        Logger.warning("[MCP Session] No auth provider configured")
        unauthenticated_context()
      end
    else
      # Get user from auth provider
      try do
        case auth_provider.current_user(conn) do
          nil ->
            if arx? do
              Logger.warning(
                "[MCP Session] No credentials from provider #{inspect(auth_provider)} in Arx mode — rejecting"
              )

              {:error, :auth_provider_error}
            else
              Logger.debug("[MCP Session] No credentials from provider #{inspect(auth_provider)}")
              unauthenticated_context()
            end

          {:error, reason} ->
            if arx? do
              Logger.warning(
                "[MCP Session] Auth provider #{inspect(auth_provider)} returned error in Arx mode: #{inspect(reason)} — rejecting"
              )

              {:error, :auth_provider_error}
            else
              Logger.warning(
                "[MCP Session] Auth provider #{inspect(auth_provider)} returned error: #{inspect(reason)}"
              )

              unauthenticated_context()
            end

          user ->
            # Build context from user
            context_from_user(user)
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

  # Returns true if the tenant (org_id/project_id) has changed between stored and fresh context.
  # Returns false for unauthenticated fresh contexts (Core mode no-op).
  defp tenant_changed?(_stored, %Context{authenticated: false}), do: false
  defp tenant_changed?(nil, _fresh), do: false

  defp tenant_changed?(stored, fresh) do
    (stored.org_id || "") != (fresh.org_id || "") or
      (stored.project_id || "default") != (fresh.project_id || "default")
  end

  defp context_from_user(user) do
    user = maybe_resolve_membership(user)

    context =
      Context.build(
        user_id: user.id,
        email: user.email,
        org_id: user.org_id,
        project_id: user.project_id,
        permissions: user.permissions,
        scope: :project,
        auth_method: :oidc,
        authenticated: true
      )

    if arx_mode?() and (is_nil(context.org_id) or context.org_id == "") do
      Logger.warning(
        "[MCPSession] Authenticated user #{user.id} has no org_id in Arx mode — rejecting"
      )

      {:error, :missing_tenant}
    else
      context
    end
  end

  # In Arx mode, if user has no org_id, try to re-resolve membership from DB.
  defp maybe_resolve_membership(user) do
    if arx_mode?() and Code.ensure_loaded?(SanctumArx.Memberships) and
         (is_nil(user.org_id) or user.org_id == "") do
      case SanctumArx.Memberships.list_by_user(user.id) do
        memberships when is_list(memberships) and memberships != [] ->
          membership =
            Enum.find(memberships, List.first(memberships), fn m ->
              m.accepted_at != nil
            end)

          %{user | org_id: membership.org_id, project_id: user.project_id || "default"}

        [] ->
          user

        {:error, reason} ->
          Logger.error(
            "[MCPSession] Failed to resolve membership for user #{user.id}: #{inspect(reason)}"
          )

          user
      end
    else
      user
    end
  end

  defp arx_mode?, do: Application.get_env(:cyfr, :edition, :core) == :arx

  # ============================================================================
  # API Key Authentication
  # ============================================================================

  @doc false
  # Extract and validate API key from Authorization header
  # Returns {:ok, context} on success, :no_key if no API key present,
  # or {:error, reason} if key is invalid
  defp extract_and_validate_api_key(conn) do
    case extract_api_key(conn) do
      nil ->
        :no_key

      key ->
        validate_api_key(conn, key)
    end
  end

  # Extract Bearer token from Authorization header if it's a CYFR API key
  defp extract_api_key(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] ->
        # Only treat as API key if it has the cyfr_ prefix
        if String.starts_with?(token, "cyfr_") do
          token
        else
          nil
        end

      _ ->
        nil
    end
  end

  # Validate API key and build context from key metadata
  defp validate_api_key(conn, key) do
    client_ip = get_client_ip(conn)

    case Sanctum.ApiKey.validate(key, client_ip: client_ip) do
      {:ok, metadata} ->
        {:ok, context_from_api_key(metadata)}

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

  # Build context from API key metadata
  defp context_from_api_key(metadata) do
    # Convert scope list to permissions MapSet
    # Scope strings must be converted to atoms for Context.has_permission?/2
    permissions =
      metadata.scope
      |> List.wrap()
      |> Enum.map(&Sanctum.Atoms.safe_to_permission_atom/1)
      |> then(fn mapped ->
        dropped = Enum.reject(mapped, &is_atom/1)

        if dropped != [],
          do: Logger.warning("[MCP Session] Dropped non-atom permissions: #{inspect(dropped)}")

        Enum.filter(mapped, &is_atom/1)
      end)

    Context.build(
      user_id: metadata[:user_id],
      org_id: metadata[:org_id],
      project_id: metadata[:project_id],
      permissions: permissions,
      scope: :project,
      auth_method: :api_key,
      api_key_type: metadata.type,
      api_key_id: metadata[:id],
      authenticated: true
    )
  end

  # Get client IP from connection.
  # X-Forwarded-For is only trusted when explicitly enabled via config,
  # since unconditional trust allows IP spoofing that defeats API key allowlists.
  defp get_client_ip(conn) do
    if trust_forwarded_header?() do
      case extract_forwarded_ip(conn) do
        {:ok, ip} -> ip
        :error -> extract_remote_ip(conn)
      end
    else
      extract_remote_ip(conn)
    end
  end

  defp trust_forwarded_header? do
    Application.get_env(:cyfr, :trust_x_forwarded_for, false)
  end

  # Extract IP from X-Forwarded-For header
  defp extract_forwarded_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] when forwarded != "" ->
        ip = forwarded |> String.split(",") |> List.first() |> String.trim()
        if valid_ip_string?(ip), do: {:ok, ip}, else: :error

      _ ->
        :error
    end
  end

  # Extract IP from conn.remote_ip tuple
  defp extract_remote_ip(conn) do
    case conn.remote_ip do
      ip when is_tuple(ip) ->
        case :inet.ntoa(ip) do
          charlist when is_list(charlist) -> to_string(charlist)
          _ -> "0.0.0.0"
        end

      _ ->
        "0.0.0.0"
    end
  end

  # Validate IP string format
  defp valid_ip_string?(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, _} -> true
      _ -> false
    end
  end

  # Error response for API key validation failures
  defp error_response(conn, :invalid_api_key) do
    conn
    |> put_resp_header("mcp-protocol-version", @protocol_version)
    |> put_status(401)
    |> Phoenix.Controller.json(%{
      "jsonrpc" => "2.0",
      "error" => %{
        "code" => Message.cyfr_code(:auth_invalid),
        "message" => "Invalid API key"
      },
      "id" => nil
    })
    |> halt()
  end

  defp error_response(conn, :api_key_revoked) do
    conn
    |> put_resp_header("mcp-protocol-version", @protocol_version)
    |> put_status(401)
    |> Phoenix.Controller.json(%{
      "jsonrpc" => "2.0",
      "error" => %{
        "code" => Message.cyfr_code(:auth_invalid),
        "message" => "API key has been revoked"
      },
      "id" => nil
    })
    |> halt()
  end

  defp error_response(conn, :ip_not_allowed) do
    conn
    |> put_resp_header("mcp-protocol-version", @protocol_version)
    |> put_status(403)
    |> Phoenix.Controller.json(%{
      "jsonrpc" => "2.0",
      "error" => %{
        "code" => Message.cyfr_code(:insufficient_permissions),
        "message" => "Request IP not in API key allowlist"
      },
      "id" => nil
    })
    |> halt()
  end

  defp error_response(conn, _reason) do
    conn
    |> put_resp_header("mcp-protocol-version", @protocol_version)
    |> put_status(401)
    |> Phoenix.Controller.json(%{
      "jsonrpc" => "2.0",
      "error" => %{
        "code" => Message.cyfr_code(:auth_invalid),
        "message" => "API key validation failed"
      },
      "id" => nil
    })
    |> halt()
  end
end
