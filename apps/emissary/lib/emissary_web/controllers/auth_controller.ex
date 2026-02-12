defmodule EmissaryWeb.AuthController do
  @moduledoc """
  OAuth authentication controller for CYFR.

  Handles OAuth/OIDC authentication flows using Ueberauth.

  ## Routes

  - `GET /auth/:provider` - Redirects to OAuth provider
  - `GET /auth/:provider/callback` - Handles OAuth callback
  - `DELETE /auth/logout` - Destroys session

  ## Usage

  Configure providers via environment variables:

      # GitHub
      export CYFR_GITHUB_CLIENT_ID=xxx
      export CYFR_GITHUB_CLIENT_SECRET=xxx

      # Google
      export CYFR_GOOGLE_CLIENT_ID=xxx
      export CYFR_GOOGLE_CLIENT_SECRET=xxx

  Then visit:

      GET /auth/github
      # or
      GET /auth/google

  """

  use EmissaryWeb, :controller

  require Logger

  # Only use Ueberauth when the module is available
  if Code.ensure_loaded?(Ueberauth) do
    plug Ueberauth
  end

  alias Sanctum.Session

  @doc """
  Initiates OAuth request to provider.

  Ueberauth handles the redirect automatically based on the :provider param.
  """
  def request(conn, _params) do
    # Ueberauth plug handles the redirect
    # This is called if no Ueberauth strategy matches
    conn
    |> put_status(:not_found)
    |> json(%{
      error: "unknown_provider",
      message: "OAuth provider not configured. Available providers depend on environment configuration."
    })
  end

  @doc """
  Handles OAuth callback from provider.

  On success:
  - Creates session for user
  - Returns JSON with session token and user info
  - For browser clients, can redirect to frontend with token

  On failure:
  - Returns JSON error
  """
  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    case authenticate_with_provider(auth) do
      {:ok, user} ->
        case Session.create(user) do
          {:ok, session} ->
            # Check for redirect_uri in session or return JSON
            redirect_uri = get_session(conn, :oauth_redirect_uri)

            if redirect_uri do
              # Redirect to frontend with token
              redirect_url = build_redirect_url(redirect_uri, session.token)

              conn
              |> delete_session(:oauth_redirect_uri)
              |> redirect(external: redirect_url)
            else
              # Return JSON response for API clients
              conn
              |> put_status(:ok)
              |> json(%{
                ok: true,
                session: %{
                  token: session.token,
                  expires_at: session.expires_at
                },
                user: %{
                  id: user.id,
                  email: user.email,
                  provider: user.provider
                }
              })
            end

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "session_error", message: friendly_error_message(reason)})
        end

      {:error, reason} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "authentication_failed", message: friendly_error_message(reason)})
    end
  end

  def callback(%{assigns: %{ueberauth_failure: failure}} = conn, _params) do
    conn
    |> put_status(:unauthorized)
    |> json(%{
      error: "oauth_failure",
      message: failure_message(failure)
    })
  end

  def callback(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: "invalid_callback",
      message: "Invalid OAuth callback. Missing auth or failure information."
    })
  end

  @doc """
  Logout - destroys the session.

  Accepts session token via:
  - Authorization: Bearer {token}
  - Request body: {"token": "..."}
  """
  def logout(conn, params) do
    token =
      get_bearer_token(conn) ||
      params["token"] ||
      safe_get_session(conn, :session_token)

    if token && token != "" do
      case Session.destroy(token) do
        :ok ->
          conn
          |> safe_drop_session()
          |> json(%{ok: true, message: "Logged out successfully"})

        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{error: "logout_failed", message: friendly_error_message(reason)})
      end
    else
      conn
      |> put_status(:bad_request)
      |> json(%{error: "missing_token", message: "No session token provided"})
    end
  end

  @doc """
  Returns current session info.

  Requires Authorization: Bearer {token} header.
  """
  def whoami(conn, _params) do
    case get_bearer_token(conn) do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "unauthorized", message: "No session token provided"})

      token ->
        case Session.get(token) do
          {:ok, session} ->
            conn
            |> json(%{
              ok: true,
              session: %{
                user_id: session.user_id,
                email: session.email,
                provider: session.provider,
                created_at: session.created_at,
                expires_at: session.expires_at
              }
            })

          {:error, _} ->
            conn
            |> put_status(:unauthorized)
            |> json(%{error: "invalid_session", message: "Invalid session token"})
        end
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp get_bearer_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  # Safe session access - returns nil if session not fetched (e.g., API routes)
  defp safe_get_session(conn, key) do
    get_session(conn, key)
  rescue
    ArgumentError -> nil
  end

  # Safe session drop - no-op if session not fetched (e.g., API routes)
  defp safe_drop_session(conn) do
    configure_session(conn, drop: true)
  rescue
    ArgumentError -> conn
  end

  defp build_redirect_url(base_uri, token) do
    uri = URI.parse(base_uri)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.put("token", token)
      |> URI.encode_query()

    %{uri | query: query}
    |> URI.to_string()
  end

  defp authenticate_with_provider(auth) do
    # Get the configured auth provider from sanctum config
    provider = Application.get_env(:sanctum, :auth_provider)

    case provider do
      # Enterprise: SanctumArx.Auth.OIDC
      SanctumArx.Auth.OIDC ->
        if Code.ensure_loaded?(SanctumArx.Auth.OIDC) do
          apply(SanctumArx.Auth.OIDC, :authenticate, [auth])
        else
          {:error, :auth_provider_not_available}
        end

      # SimpleOAuth: Standard GitHub/Google OAuth
      Sanctum.Auth.SimpleOAuth ->
        Sanctum.Auth.SimpleOAuth.authenticate(auth)

      # No provider configured
      nil ->
        {:error, :auth_provider_not_configured}

      _other ->
        {:error, :auth_provider_not_supported}
    end
  end

  defp failure_message(%{errors: errors}) when is_list(errors) do
    errors
    |> Enum.map(fn
      %{message: msg} -> msg
      _error -> "Authentication error"
    end)
    |> Enum.join(", ")
  end

  defp failure_message(_failure), do: "Authentication failed"

  # Maps internal error atoms/tuples to user-friendly messages
  # without exposing implementation details
  defp friendly_error_message(:session_not_found), do: "Session not found"
  defp friendly_error_message(:session_expired), do: "Session has expired"
  defp friendly_error_message(:invalid_token), do: "Invalid session token"
  defp friendly_error_message(:storage_error), do: "Unable to process request"
  defp friendly_error_message(:auth_provider_not_configured), do: "Authentication provider not configured"
  defp friendly_error_message(:auth_provider_not_available), do: "Authentication provider not available"
  defp friendly_error_message(:auth_provider_not_supported), do: "Authentication provider not supported"
  defp friendly_error_message({:validation_error, _}), do: "Invalid authentication data"
  defp friendly_error_message({:provider_error, _}), do: "Authentication provider error"
  defp friendly_error_message(reason) do
    Logger.warning("Unhandled auth error: #{inspect(reason)}")
    "An error occurred during authentication"
  end
end
