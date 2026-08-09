# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

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
    # This is the only edge from the auth sliver into Compendium in the web
    # flow (DeviceFlow is the CLI counterpart).
    access_token = extract_access_token(auth)

    case authenticate_with_provider(auth) do
      {:ok, ctx} ->
        case Session.create(ctx) do
          {:ok, session} ->
            # Seed CredentialStore with push tokens via cyfr.run probe.
            case probe_and_store(ctx, access_token, auth.provider) do
              {:reauthenticate, provider, reason} ->
                # Recovery requires a fresh IdP access_token:
                #   :idp_expired — probe returned 401; the current token is dead.
                #   :local_store_failed — the personal push token landed on
                #     cyfr.run but our CredentialStore.put failed. cyfr.run's
                #     /v1/namespaces/personal/claim is not idempotent for the
                #     same identity (returns 409 ALREADY_CLAIMED), so re-auth
                #     is the only clean path to mint a fresh push token.
                _ = Session.destroy(session.token)

                conn
                |> safe_drop_session()
                |> put_flash_if_available(:error, reauth_flash_message(reason))
                |> redirect(to: "/auth/#{provider}")

              {:needs_policy_acceptance, _required_version} ->
                # Probe gate: cyfr.run requires acceptance of the current
                # bundled policy_version before any token mint. Stash the
                # access_token so /auth/post-legal-accept can re-probe
                # after the user clickwraps. Session is created — the user
                # is logged in — but no push tokens minted yet.
                conn
                |> put_session(:sanctum_session_token, session.token)
                |> stash_pending_probe(access_token)
                |> redirect(to: "/legal/accept")

              {:ok, needs_claim?, suggested_username, warnings} ->
                conn =
                  conn
                  |> put_session(:sanctum_session_token, session.token)
                  |> maybe_stash_pending_probe(access_token, needs_claim?)
                  |> maybe_flash_warnings(warnings)

                if needs_claim? do
                  # Dashboard access is gated until the user claims a personal
                  # namespace.
                  conn
                  |> put_session(:claim_suggested_username, suggested_username || "")
                  |> redirect(to: "/claim-namespace")
                else
                  # Return JSON response for API clients.
                  conn
                  |> put_status(:ok)
                  |> json(%{
                    ok: true,
                    session: %{
                      token: session.token,
                      expires_at: session.expires_at
                    },
                    user: %{
                      id: ctx.user_id,
                      email: ctx.email,
                      provider: ctx.provider
                    },
                    warnings: warnings
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

  @doc """
  Post-legal-accept landing handler. The user just submitted /legal/accept
  and we need to re-run probe_and_store with the still-valid IdP
  access_token (stashed in `_cyfr_pending_probe`). Routes to
  /claim-namespace if the user still needs to claim a personal namespace,
  else to the dashboard.

  Closes the loop:
    probe → 412 → /legal/accept → /auth/post-legal-accept → probe → ok
  """
  def post_legal_accept(conn, _params) do
    conn = fetch_cookies(conn, signed: ["_cyfr_pending_probe"])
    access_token = conn.cookies["_cyfr_pending_probe"]
    session_token = get_session(conn, :sanctum_session_token)

    cond do
      not is_binary(access_token) or access_token == "" ->
        # Cookie expired (10 min TTL) or never set. Force fresh OAuth.
        Logger.info(
          "[EmissaryWeb.AuthController] post_legal_accept: missing _cyfr_pending_probe; " <>
            "redirecting to OAuth"
        )

        conn |> redirect(to: "/auth/github")

      not is_binary(session_token) or session_token == "" ->
        conn |> redirect(to: "/auth/github")

      true ->
        case Sanctum.Session.load(session_token) do
          {:ok, ctx} ->
            provider = ctx.provider || "github"

            case probe_and_store(ctx, access_token, provider) do
              {:reauthenticate, prov, _reason} ->
                conn
                |> delete_resp_cookie("_cyfr_pending_probe")
                |> redirect(to: "/auth/#{prov}")

              {:needs_policy_acceptance, _v} ->
                # Server bumped between accept and re-probe. Loop back.
                conn |> redirect(to: "/legal/accept")

              {:ok, true, suggested_username, warnings} ->
                # Probe succeeded but user has no personal namespace yet.
                conn
                |> put_session(:claim_suggested_username, suggested_username || "")
                |> maybe_flash_warnings(warnings)
                |> redirect(to: "/claim-namespace")

              {:ok, false, _suggested, warnings} ->
                # Fully set up. Clear pending probe + go to the landing target.
                conn
                |> delete_resp_cookie("_cyfr_pending_probe")
                |> maybe_flash_warnings(warnings)
                |> EmissaryWeb.SafeRedirect.post_login()
            end

          _ ->
            conn |> redirect(to: "/auth/github")
        end
    end
  end

  # Pulls the IdP access_token from the Ueberauth struct. Both GitHub and
  # Google strategies populate `auth.credentials.token`. A configured OIDC
  # provider (ueberauth_oidcc) also populates it. Nil when absent.
  defp extract_access_token(%{credentials: %{token: token}}) when is_binary(token), do: token
  defp extract_access_token(_), do: nil

  # Returns one of:
  # - `{:ok, needs_claim?, suggested_username, warnings}` — probe succeeded
  #   (or failed transiently); `warnings` is a list of slugs whose push tokens
  #   were issued server-side but couldn't be cached locally. Caller surfaces
  #   these via flash (browser) or `warnings:` key (JSON).
  # - `{:reauthenticate, provider, reason}` — session must be destroyed and
  #   the user bounced back through OAuth. `reason` is either `:idp_expired`
  #   (probe returned 401) or `:local_store_failed` (personal push token was
  #   minted on cyfr.run but couldn't be stored locally; cyfr.run's claim
  #   endpoint isn't idempotent so a fresh access_token is the only recovery).
  defp probe_and_store(_ctx, nil, _provider) do
    Logger.warning(
      "[EmissaryWeb.AuthController] no access_token on Ueberauth struct — skipping probe; " <>
        "user will need to re-authenticate or claim namespace manually"
    )

    # Don't force the gate just because the access_token is absent — the user
    # might have a valid session via an IdP that doesn't expose one. They'll
    # hit the gate on browser page loads only if CredentialStore is empty.
    {:ok, false, nil, []}
  end

  defp probe_and_store(ctx, access_token, provider) do
    case Compendium.Registry.Client.probe_identity(provider, access_token) do
      {:ok, body} ->
        registry = Compendium.Registry.canonical_host()
        {personal_stored?, warnings} = store_probe_results(ctx.user_id, registry, body)

        personal = body["personal_namespace"]

        cond do
          is_nil(personal) ->
            # Probe succeeded but the user hasn't claimed a personal namespace
            # yet. Gate them until they do.
            {:ok, true, suggest_username(ctx), warnings}

          not personal_stored? ->
            # Personal push token was issued by cyfr.run but the local
            # CredentialStore.put failed. Retrying the claim endpoint would
            # 409 ALREADY_CLAIMED (not idempotent per identity); a fresh probe
            # needs a fresh access_token, so we force re-auth.
            Logger.warning(
              "[EmissaryWeb.AuthController] CredentialStore.put failed for personal " <>
                "slug #{inspect(personal["slug"])} — bouncing to OAuth for fresh access_token"
            )

            {:reauthenticate, provider, :local_store_failed}

          true ->
            {:ok, false, nil, warnings}
        end

      {:error, :invalid_access_token} ->
        Logger.warning(
          "[EmissaryWeb.AuthController] probe_identity returned 401 invalid_access_token; " <>
            "destroying session and redirecting to /auth/#{provider}"
        )

        {:reauthenticate, provider, :idp_expired}

      {:error, %Compendium.OCI.Errors{reason: :policy_acceptance_required} = err} ->
        required =
          case err.detail do
            %{required_version: v} when is_binary(v) -> v
            %{"required_version" => v} when is_binary(v) -> v
            _ -> nil
          end

        Logger.info(
          "[EmissaryWeb.AuthController] probe_identity returned 412 — policy " <>
            "acceptance required (version: #{inspect(required)})"
        )

        {:needs_policy_acceptance, required}

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

  # Returns `{personal_stored?, warnings}`.
  #
  # `personal_stored?` is `true` when probe returned no personal namespace
  # (nothing to store) OR when the personal-slug put succeeded. It is `false`
  # only when the personal put actually failed — this distinction drives the
  # caller's decision to force re-auth vs. let the user continue.
  #
  # `warnings` is a list of slugs whose push tokens cyfr.run issued but the
  # local CredentialStore couldn't cache — membership failures always appear;
  # the personal slug appears only when its put failed (caller still forces
  # re-auth but the slug is visible in logs).
  defp store_probe_results(user_id, registry, body) do
    personal = body["personal_namespace"]
    memberships = body["memberships"] || []

    {personal_stored?, personal_warning} =
      case personal do
        nil ->
          {true, nil}

        %{"slug" => slug, "token" => _} ->
          case Compendium.Registry.CredentialStore.put_push_token(
                 user_id,
                 registry,
                 slug,
                 personal["token"],
                 "personal"
               ) do
            :ok -> {true, nil}
            :skipped -> {true, nil}
            {:error, _} -> {false, slug}
          end

        _ ->
          {true, nil}
      end

    membership_warnings =
      Enum.flat_map(memberships, fn m ->
        case Compendium.Registry.CredentialStore.put_push_token(
               user_id,
               registry,
               m["slug"],
               m["token"],
               m["role"] || "member"
             ) do
          :ok -> []
          :skipped -> []
          {:error, _} -> [m["slug"]]
        end
      end)

    warnings = Enum.reject([personal_warning | membership_warnings], &is_nil/1)

    if warnings != [] do
      Logger.info(
        "[EmissaryWeb.AuthController] probe stored partial credentials; failed slugs=" <>
          inspect(warnings)
      )
    end

    {personal_stored?, warnings}
  end

  # Email local-part normalized to the server-side personal-slug shape
  # (see `Sanctum.Context.suggest_slug/1`). Returns nil when the local-part
  # can't be reduced to a valid slug — the claim-gate UI then shows an
  # empty field.
  defp suggest_username(%{email: email}), do: Sanctum.Context.suggest_slug(email)
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

  # Unconditional sibling of maybe_stash_pending_probe/3. Used by the
  # probe-policy-acceptance gate path: we always need the access_token
  # available to /auth/post-legal-accept regardless of whether the user
  # also needs to claim a personal namespace afterwards.
  defp stash_pending_probe(conn, access_token) when is_binary(access_token) do
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

  # Surface credential-store warnings to the user so they know some push
  # tokens didn't land locally. Membership failures are the common case;
  # `cyfr registry probe` re-mints and re-stores. Only called on redirect
  # paths (browser) — JSON-response branch surfaces warnings in the payload.
  defp maybe_flash_warnings(conn, []), do: conn

  defp maybe_flash_warnings(conn, warnings) do
    msg =
      "Some cyfr.run tokens didn't fully sync: " <>
        Enum.join(warnings, ", ") <>
        ". Run `cyfr registry probe` to retry."

    put_flash_if_available(conn, :error, msg)
  end

  defp reauth_flash_message(:local_store_failed) do
    "Your cyfr.run credential couldn't be stored locally. Please sign in again."
  end

  defp reauth_flash_message(:idp_expired) do
    "Your login session expired during credential setup. Please sign in again."
  end

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

  defp authenticate_with_provider(auth) do
    # Dispatch generically to whatever module is configured. Both
    # Sanctum.Auth.OAuth and the configured auth provider implement authenticate/1.
    case Application.get_env(:cyfr, :auth_provider) do
      nil ->
        {:error, :auth_provider_not_configured}

      provider when is_atom(provider) ->
        try do
          provider.authenticate(auth)
        rescue
          UndefinedFunctionError -> {:error, :auth_provider_not_available}
        end

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

  defp friendly_error_message(:email_not_verified),
    do: "Your provider reported an unverified email. Please verify your email and try again."

  defp friendly_error_message(:missing_email),
    do:
      "Your provider did not return an email address. Please check your account privacy settings and try again."

  defp friendly_error_message({:validation_error, _}), do: "Invalid authentication data"
  defp friendly_error_message({:provider_error, _}), do: "Authentication provider error"

  defp friendly_error_message(reason) do
    Logger.warning("Unhandled auth error: #{inspect(reason)}")
    "An error occurred during authentication"
  end
end
