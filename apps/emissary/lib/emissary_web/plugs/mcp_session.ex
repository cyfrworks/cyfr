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

  def call(conn, _opts) do
    # Check API key first - this is stateless auth that bypasses sessions
    case extract_and_validate_api_key(conn) do
      {:ok, context} ->
        # API key auth successful - no session needed
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
  end

  # Session-based authentication flow
  defp handle_session_auth(conn) do
    session_id = get_session_id(conn)
    context = get_context(conn)

    cond do
      # Has valid session ID
      session_id && Session.exists?(session_id) ->
        {:ok, session} = Session.get(session_id)
        # Async refresh SQLite expiration (activity-based TTL)
        Task.start(fn -> Sanctum.Session.refresh(session_id) end)
        conn
        |> assign(:mcp_session, session)
        |> assign(:mcp_context, session.context)

      # Has session ID but it's invalid/expired (in memory)
      session_id ->
        # Try to hydrate from persistent storage before returning error
        case Sanctum.Session.get_user(session_id) do
          {:ok, user} ->
            context = context_from_user(user)
            {:ok, session} = Session.hydrate(session_id, context)
            # Extend session expiration on successful hydration (activity-based TTL)
            _ = Sanctum.Session.refresh(session_id)

            conn
            |> assign(:mcp_session, session)
            |> assign(:mcp_context, session.context)

          _ ->
            # Allow initialize requests through — the client may be re-initializing
            # with a stale session ID cached from a previous server lifecycle.
            # Guard: body_params may be %Plug.Conn.Unfetched{} in tests or if
            # Plug.Parsers hasn't run yet, so check it's a map first.
            if is_map(conn.body_params) and not is_struct(conn.body_params) and
                 conn.body_params["method"] == "initialize" do
              conn
              |> assign(:mcp_session, nil)
              |> assign(:mcp_context, get_context(conn))
            else
              conn
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

      # No session ID - this is expected for initialize request
      true ->
        conn
        |> assign(:mcp_session, nil)
        |> assign(:mcp_context, context)
    end
  end

  defp get_session_id(conn) do
    case get_req_header(conn, "mcp-session-id") do
      [id | _] -> id
      [] -> nil
    end
  end

  defp get_context(conn) do
    # Get auth provider from config
    auth_provider = Application.get_env(:sanctum, :auth_provider)

    if is_nil(auth_provider) do
      Logger.warning("[MCP Session] No auth provider configured")
      unauthenticated_context()
    else
      # Get user from auth provider
      case auth_provider.current_user(conn) do
        nil ->
          Logger.warning("[MCP Session] Auth failed for provider #{inspect(auth_provider)} - returning unauthenticated context")
          unauthenticated_context()

        user ->
          # Build context from user
          context_from_user(user)
      end
    end
  end

  defp unauthenticated_context do
    %Context{
      user_id: nil,
      org_id: nil,
      permissions: MapSet.new(),
      scope: :personal,
      auth_method: nil,
      api_key_type: nil,
      request_id: nil,
      session_id: nil,
      authenticated: false
    }
  end

  defp context_from_user(user) do
    %Context{
      user_id: user.id,
      org_id: nil,
      permissions: MapSet.new(user.permissions),
      scope: :personal,
      authenticated: true
    }
  end

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
      |> Enum.filter(&is_atom/1)
      |> MapSet.new()

    %Context{
      user_id: metadata[:user_id],
      org_id: metadata[:org_id],
      permissions: permissions,
      scope: :personal,
      auth_method: :api_key,
      api_key_type: metadata.type,
      request_id: nil,
      session_id: nil,
      authenticated: true
    }
  end

  # Get client IP from connection (handles proxy headers)
  defp get_client_ip(conn) do
    case extract_forwarded_ip(conn) do
      {:ok, ip} -> ip
      :error -> extract_remote_ip(conn)
    end
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
    |> put_status(401)
    |> Phoenix.Controller.json(%{
      "jsonrpc" => "2.0",
      "error" => %{
        "code" => Message.cyfr_code(:unauthorized),
        "message" => "Invalid API key"
      },
      "id" => nil
    })
    |> halt()
  end

  defp error_response(conn, :api_key_revoked) do
    conn
    |> put_status(401)
    |> Phoenix.Controller.json(%{
      "jsonrpc" => "2.0",
      "error" => %{
        "code" => Message.cyfr_code(:unauthorized),
        "message" => "API key has been revoked"
      },
      "id" => nil
    })
    |> halt()
  end

  defp error_response(conn, :ip_not_allowed) do
    conn
    |> put_status(403)
    |> Phoenix.Controller.json(%{
      "jsonrpc" => "2.0",
      "error" => %{
        "code" => Message.cyfr_code(:forbidden),
        "message" => "Request IP not in API key allowlist"
      },
      "id" => nil
    })
    |> halt()
  end

  defp error_response(conn, _reason) do
    conn
    |> put_status(401)
    |> Phoenix.Controller.json(%{
      "jsonrpc" => "2.0",
      "error" => %{
        "code" => Message.cyfr_code(:unauthorized),
        "message" => "API key validation failed"
      },
      "id" => nil
    })
    |> halt()
  end
end
