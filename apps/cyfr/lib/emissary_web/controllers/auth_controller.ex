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

  Then visit:

      GET /auth/github

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
      message:
        "OAuth provider not configured. Available providers depend on environment configuration."
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
    # Accepted cross-layer coupling: this controller is part of the auth
    # sliver but intentionally calls Compendium.Registry.Client.probe_identity/3
    # and Compendium.Registry.CredentialStore.put/4 after Session.create/1.
    # See auth_refactor.md §"Accepted cross-layer coupling".
    access_token = extract_access_token(auth)

    case authenticate_with_provider(auth) do
      {:ok, user} ->
        case Session.create(user) do
          {:ok, session} ->
            # Seed CredentialStore with push tokens via cyfr.run probe.
            case probe_and_store(user, access_token, auth.provider) do
              {:reauthenticate, provider} ->
                # IdP access_token expired between OAuth completion and probe.
                # Destroy the just-created session and bounce back through OAuth.
                # See auth_refactor.md §3 step 6.
                _ = Session.destroy(session.token)

                conn
                |> safe_drop_session()
                |> put_flash_if_available(
                  :error,
                  "Your login session expired during credential setup. Please sign in again."
                )
                |> redirect(to: "/auth/#{provider}")

              {:ok, needs_claim?, suggested_username, _warnings} ->
                conn =
                  conn
                  |> put_session(:sanctum_session_token, session.token)
                  |> maybe_stash_pending_probe(access_token, needs_claim?)

                redirect_uri = get_session(conn, :oauth_redirect_uri)

                cond do
                  needs_claim? ->
                    # Dashboard access is gated until the user claims a personal
                    # namespace. `oauth_redirect_uri` is preserved in session and
                    # honored post-claim.
                    conn
                    |> put_session(:claim_suggested_username, suggested_username || "")
                    |> redirect(to: "/claim-namespace")

                  redirect_uri ->
                    # Redirect to frontend with token
                    redirect_url = build_redirect_url(redirect_uri, session.token)

                    conn
                    |> delete_session(:oauth_redirect_uri)
                    |> redirect(external: redirect_url)

                  true ->
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

  # Pulls the IdP access_token from the Ueberauth struct. Both GitHub and
  # Google strategies populate `auth.credentials.token`. Enterprise OIDC
  # (ueberauth_oidcc) also populates it. Nil when absent.
  defp extract_access_token(%{credentials: %{token: token}}) when is_binary(token), do: token
  defp extract_access_token(_), do: nil

  # Returns one of:
  # - `{:ok, needs_claim?, suggested_username, warnings}` — probe succeeded
  #   (or failed transiently); `warnings` is a list of slugs whose push tokens
  #   were issued server-side but couldn't be cached locally. Caller may
  #   surface these via flash.
  # - `{:reauthenticate, provider}` — IdP access_token expired; caller must
  #   destroy the session and redirect to OAuth. See auth_refactor.md §3
  #   step 6.
  defp probe_and_store(_user, nil, _provider) do
    Logger.warning(
      "[EmissaryWeb.AuthController] no access_token on Ueberauth struct — skipping probe; " <>
        "user will need to re-authenticate or claim namespace manually"
    )

    # Don't force the gate just because the access_token is absent — the user
    # might have a valid session via an IdP that doesn't expose one. They'll
    # hit the gate on browser page loads only if CredentialStore is empty.
    {:ok, false, nil, []}
  end

  defp probe_and_store(user, access_token, provider) do
    case Compendium.Registry.Client.probe_identity(provider, access_token) do
      {:ok, body} ->
        registry = Compendium.Edition.cyfr_run_registry()

        warnings = store_probe_results(user.id, registry, body)

        personal = body["personal_namespace"]

        if personal do
          {:ok, false, nil, warnings}
        else
          # Probe succeeded but the user hasn't claimed a personal namespace
          # yet. Gate them until they do.
          {:ok, true, suggest_username(user), warnings}
        end

      {:error, :invalid_access_token} ->
        Logger.warning(
          "[EmissaryWeb.AuthController] probe_identity returned 401 invalid_access_token; " <>
            "destroying session and redirecting to /auth/#{provider}"
        )

        {:reauthenticate, provider}

      {:error, err} ->
        # Network / server-side probe failure — don't block session creation.
        # The user lands on the dashboard; the browser-side plug will route
        # them through the claim-gate when CredentialStore is empty.
        Logger.warning(
          "[EmissaryWeb.AuthController] probe_identity failed — #{inspect(err)}; " <>
            "session created without push-token seeding, gate will prompt on next page load"
        )

        {:ok, false, nil, []}
    end
  end

  # Returns a list of slugs whose `CredentialStore.put/4` failed. Partial
  # failures don't abort — every namespace is attempted.
  defp store_probe_results(user_id, registry, body) do
    personal = body["personal_namespace"]
    memberships = body["memberships"] || []

    personal_warning =
      if personal do
        case put_cred(user_id, registry, personal["slug"], personal["token"], "personal") do
          :ok -> nil
          :skipped -> nil
          {:error, _} -> personal["slug"]
        end
      end

    membership_warnings =
      Enum.flat_map(memberships, fn m ->
        case put_cred(user_id, registry, m["slug"], m["token"], m["role"] || "member") do
          :ok -> []
          :skipped -> []
          {:error, _} -> [m["slug"]]
        end
      end)

    Enum.reject([personal_warning | membership_warnings], &is_nil/1)
  end

  defp put_cred(user_id, registry, slug, token, role)
       when is_binary(slug) and is_binary(token) do
    cred = %{
      type: :push_token,
      token: token,
      namespace: slug,
      role: role,
      issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      label: Compendium.Registry.Client.device_label()
    }

    case Compendium.Registry.CredentialStore.put(user_id, registry, slug, cred) do
      :ok ->
        :ok

      {:error, reason} = err ->
        Logger.warning(
          "[EmissaryWeb.AuthController] CredentialStore.put failed for #{slug}: " <>
            "#{inspect(reason)} — leaving orphan cyfr.run token (server-side reaper backstop)"
        )

        err
    end
  end

  defp put_cred(_user_id, _registry, _slug, _token, _role), do: :skipped

  # Email local-part normalized to the server-side personal-slug shape
  # (see `Sanctum.User.suggest_slug/1`). Returns nil when the local-part
  # can't be reduced to a valid slug — the claim-gate UI then shows an
  # empty field.
  defp suggest_username(%{email: email}), do: Sanctum.User.suggest_slug(email)
  defp suggest_username(_), do: nil

  defp maybe_stash_pending_probe(conn, access_token, true)
       when is_binary(access_token) do
    # 10-min TTL signed-cookie holds the access_token for a single retry /
    # claim submission. Not stored in LiveView assigns (endpoint restarts
    # lose them) and not in the session DB (secret sprawl).
    #
    # Guarded against missing secret_key_base (e.g., some test-only conn
    # paths). The cookie is a UX nicety; absence means the user must
    # re-authenticate to retry the probe.
    try do
      put_resp_cookie(conn, "_cyfr_pending_probe", access_token,
        sign: true,
        max_age: 600,
        http_only: true,
        same_site: "Lax",
        secure: Application.get_env(:cyfr, :cookie_secure, false)
      )
    rescue
      e ->
        Logger.warning(
          "[EmissaryWeb.AuthController] failed to stash pending_probe cookie: #{Exception.message(e)}"
        )

        conn
    end
  end

  defp maybe_stash_pending_probe(conn, _access_token, _needs_claim?), do: conn

  # Put a flash message only if flash is available on the conn. OAuth callback
  # routes are under the `:browser` pipeline so flash is normally set up, but
  # some test paths exercise the controller without the full plug stack.
  defp put_flash_if_available(conn, kind, msg) do
    Phoenix.Controller.put_flash(conn, kind, msg)
  rescue
    _ -> conn
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
    provider = Application.get_env(:cyfr, :auth_provider)

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
  defp friendly_error_message(:database_error), do: "Unable to process request"

  defp friendly_error_message(:auth_provider_not_configured),
    do: "Authentication provider not configured"

  defp friendly_error_message(:auth_provider_not_available),
    do: "Authentication provider not available"

  defp friendly_error_message(:auth_provider_not_supported),
    do: "Authentication provider not supported"

  defp friendly_error_message({:validation_error, _}), do: "Invalid authentication data"
  defp friendly_error_message({:provider_error, _}), do: "Authentication provider error"

  defp friendly_error_message(reason) do
    Logger.warning("Unhandled auth error: #{inspect(reason)}")
    "An error occurred during authentication"
  end
end
