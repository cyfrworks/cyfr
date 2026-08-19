# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.AuthController do
  @moduledoc """
  OAuth authentication controller for CYFR.

  Handles OAuth/OIDC authentication flows using Ueberauth.

  ## Routes

  - `GET /auth/:provider` - Redirects to OAuth provider
  - `GET /auth/:provider/callback` - Handles OAuth callback (redirects; the
    session token lives in the cookie, never in a body)
  - `GET /auth/post-legal-accept` - Re-probes after policy acceptance
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

  plug Ueberauth

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
  Handles the OAuth callback from the provider — the browser sign-in.

  Door → what sign-in records → the one decision (`Sanctum.SignIn.complete/3`)
  → a session and a redirect. Every outcome is a redirect or a page; the
  session token travels in the cookie and nowhere else.

  - proceed → session, cookie, `/`
  - policy acceptance required → session, cookie, `/legal/accept`
  - claim required → session (loads unauthenticated until the claim), cookie,
    `/claim-namespace`
  - IdP token refused → no session, back through `/auth/:provider`
  - a first-time person and no registry answer → no session, a page saying so
  - refused at the door → 403 page, no session, no cyfr.run call
  """
  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    access_token = extract_access_token(auth)
    provider = auth.provider

    with {:ok, ctx} <- authenticate_with_provider(auth),
         {:ok, ctx, user} <- admit(ctx, auth) do
      case Sanctum.SignIn.complete(user, provider, access_token) do
        {:proceed, user, report} ->
          # The athanor may have been minted a moment ago: resolve again so
          # the session names it.
          ctx = Sanctum.Tenancy.resolve_into(%{ctx | namespace: user.namespace}, force: true)

          with_session(conn, ctx, fn conn, _session ->
            conn
            |> flash_report(report)
            |> EmissaryWeb.SafeRedirect.post_login()
          end)

        {:needs_legal, _required_version} ->
          # cyfr.run requires acceptance of the current policy before any
          # token mint. The IdP token is stashed for /auth/post-legal-accept
          # to re-probe once the person has accepted.
          with_session(conn, ctx, fn conn, _session ->
            conn
            |> stash_pending_probe(access_token)
            |> redirect(to: "/legal/accept")
          end)

        {:needs_claim, suggested} ->
          # No personal namespace yet: the session loads unauthenticated
          # until the claim, and the console is gated until then.
          with_session(conn, ctx, fn conn, _session ->
            conn
            |> stash_pending_probe(access_token)
            |> put_session(:claim_suggested_username, suggested || "")
            |> redirect(to: "/claim-namespace")
          end)

        {:reauthenticate, reason} ->
          conn
          |> safe_drop_session()
          |> put_flash_if_available(:error, reauth_flash_message(reason))
          |> redirect(to: "/auth/#{provider}")

        {:unavailable, reason} ->
          # Nothing was set up and no session exists: the person tries again.
          conn
          |> safe_drop_session()
          |> put_status(:service_unavailable)
          |> put_resp_content_type("text/html")
          |> send_resp(503, unavailable_page(reason))
      end
    else
      {:error, {:door, _reason}} ->
        # Refused at the door: no session, no cookie, no cyfr.run call. One
        # message whichever branch refused.
        conn
        |> put_status(:forbidden)
        |> put_resp_content_type("text/html")
        |> send_resp(403, door_refusal_page())

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
  Post-legal-accept landing handler. The person just submitted /legal/accept
  and the probe re-runs with the still-valid IdP access_token (stashed in
  `_cyfr_pending_probe`): the same decision as the callback, from a session
  that already exists.

  Closes the loop:
    probe → 412 → /legal/accept → /auth/post-legal-accept → probe → ok
  """
  def post_legal_accept(conn, _params) do
    conn = fetch_cookies(conn, encrypted: ["_cyfr_pending_probe"])
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
        with {:ok, ctx} <- Sanctum.Session.load(session_token, surface: :console),
             {:ok, user} <- Sanctum.Tenancy.Users.get(ctx.user_id) do
          provider = ctx.provider || "github"

          case Sanctum.SignIn.complete(user, provider, access_token) do
            {:proceed, _user, report} ->
              conn
              |> delete_resp_cookie("_cyfr_pending_probe")
              |> flash_report(report)
              |> EmissaryWeb.SafeRedirect.post_login()

            {:needs_legal, _v} ->
              # Server bumped between accept and re-probe. Loop back.
              conn |> redirect(to: "/legal/accept")

            {:needs_claim, suggested} ->
              conn
              |> put_session(:claim_suggested_username, suggested || "")
              |> redirect(to: "/claim-namespace")

            {:reauthenticate, _reason} ->
              _ = Session.destroy(session_token)

              conn
              |> delete_resp_cookie("_cyfr_pending_probe")
              |> safe_drop_session()
              |> redirect(to: "/auth/#{provider}")

            {:unavailable, reason} ->
              conn
              |> put_status(:service_unavailable)
              |> put_resp_content_type("text/html")
              |> send_resp(503, unavailable_page(reason, "/auth/post-legal-accept"))
          end
        else
          _ -> conn |> redirect(to: "/auth/github")
        end
    end
  end

  # Pulls the IdP access_token from the Ueberauth struct. Both GitHub and
  # Google strategies populate `auth.credentials.token`. A configured OIDC
  # provider (ueberauth_oidcc) also populates it. Nil when absent.
  defp extract_access_token(%{credentials: %{token: token}}) when is_binary(token), do: token
  defp extract_access_token(_), do: nil

  # The session, then the cookie, then whatever the outcome renders. A
  # session that cannot be written is a 500 — the only non-redirect answer a
  # browser sees on an admitted sign-in.
  defp with_session(conn, ctx, fun) do
    case Session.create(ctx) do
      {:ok, session} ->
        conn
        |> put_session(:sanctum_session_token, session.token)
        |> fun.(session)

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "session_error", message: friendly_error_message(reason)})
    end
  end

  # 10-min encrypted cookie holding the IdP access_token for the one thing
  # that still needs it: the claim submission, or the re-probe after legal
  # acceptance. Not stored in the session DB (secret sprawl). Guarded
  # against a missing secret_key_base (some test-only conn paths) — the
  # cookie is what makes the claim possible, and its absence is logged.
  defp stash_pending_probe(conn, access_token) when is_binary(access_token) do
    try do
      put_resp_cookie(conn, "_cyfr_pending_probe", access_token,
        # Encrypted, not merely signed: a signed cookie's value is plaintext
        # to anyone who can read it, and this one holds a live IdP access
        # token.
        encrypt: true,
        max_age: 600,
        http_only: true,
        same_site: "Lax",
        secure: Cyfr.RuntimeConfig.cookie_secure?()
      )
    rescue
      e ->
        Logger.warning(
          "[EmissaryWeb.AuthController] failed to stash pending_probe cookie: #{Exception.message(e)}"
        )

        conn
    end
  end

  # What the registry said, when it matters to the person: push tokens that
  # didn't land locally (`cyfr registry probe` re-mints and re-stores), or a
  # probe that could not run at all — the sign-in stands either way.
  defp flash_report(conn, %{unsynced: unsynced, probe: probe}) do
    conn =
      case unsynced do
        [] ->
          conn

        slugs ->
          put_flash_if_available(
            conn,
            :error,
            "Some cyfr.run tokens didn't fully sync: " <>
              Enum.join(slugs, ", ") <> ". Run `cyfr registry probe` to retry."
          )
      end

    case probe do
      :failed ->
        put_flash_if_available(
          conn,
          :error,
          "cyfr.run couldn't be reached — you're signed in; push credentials refresh next time."
        )

      :invalid_token ->
        put_flash_if_available(
          conn,
          :error,
          "cyfr.run refused the sign-in token — you're signed in; sign in again before pushing."
        )

      _ ->
        conn
    end
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

  The credential comes from `Authorization: Bearer` and nowhere else. It
  used to be accepted from the request body too, which put a live session
  token into access logs and `Referer` headers for the one request whose
  whole purpose is retiring it — and `whoami`, next door, has always
  required the header.
  """
  def logout(conn, _params) do
    token = get_bearer_token(conn)

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

  # Safe session drop - no-op if session not fetched (e.g., API routes)
  defp safe_drop_session(conn) do
    configure_session(conn, drop: true)
  rescue
    ArgumentError -> conn
  end

  # The door, then what sign-in records — before any session exists and
  # before cyfr.run hears of the identity. It runs here, at the one place the
  # web flow mints a session, so no auth provider (built-in or a deployment's
  # own) can step around it. What the provider proved about the email decides
  # how the door reads it.
  defp admit(%Sanctum.Context{} = ctx, auth) do
    email = ctx.email
    extra = Map.get(auth, :extra) || %{}
    provider = Map.get(auth, :provider)

    verified =
      case Sanctum.Auth.EmailVerification.verify_with_claim(provider, email, extra) do
        {:ok, claim} -> claim
        {:error, _} -> :unknown
      end

    user_info = %{
      id: ctx.user_id,
      provider: ctx.provider || to_string(provider),
      email: email,
      verified: verified,
      name: screen_name(auth)
    }

    with {:ok, verdict} <- Sanctum.Door.admit_identity(ctx.user_id, user_info),
         {:ok, user} <- Sanctum.SignIn.admitted(user_info, verdict) do
      # No re-resolve here. An operator's first sign-in seats them in Home a
      # moment before their own athanor exists, and an athanor pinned to the
      # context now is the one every later resolve keeps — they would land in
      # Home rather than their own chat. The proceed arm resolves once the
      # mint has happened; the legal and claim arms mint a session with no
      # athanor at all, which `Sanctum.Session.create/1` re-resolves on load.
      {:ok, ctx, user}
    end
  end

  # The IdP screen name, persisted on the person's row.
  defp screen_name(%{info: info}) when is_map(info) do
    Map.get(info, :name) || Map.get(info, :nickname)
  end

  defp screen_name(_), do: nil

  # A refused sign-in lands on a plain page: the person has no session and
  # nothing of the console is theirs to see.
  defp door_refusal_page do
    message = Plug.HTML.html_escape(Sanctum.Door.refusal_message())

    """
    <!doctype html>
    <html lang="en">
    <head><meta charset="utf-8"><title>Not allowed</title>
    <style>body{font-family:system-ui,sans-serif;max-width:32rem;margin:6rem auto;padding:0 1rem;color:#222}</style>
    </head>
    <body><h1>Not allowed on this server</h1><p>#{message}</p></body>
    </html>
    """
  end

  # A first-time person whom the registry could not place: nothing was set
  # up and there is no session — a plain page and a way to try again.
  defp unavailable_page(reason, retry_path \\ "/login") do
    {title, message} = unavailable_copy(reason)
    href = Plug.HTML.html_escape(retry_path)

    """
    <!doctype html>
    <html lang="en">
    <head><meta charset="utf-8"><title>#{title}</title>
    <style>body{font-family:system-ui,sans-serif;max-width:32rem;margin:6rem auto;padding:0 1rem;color:#222}</style>
    </head>
    <body><h1>#{title}</h1><p>#{message}</p><p><a href="#{href}">Try again</a></p></body>
    </html>
    """
  end

  defp unavailable_copy(:registry_unreachable) do
    {"cyfr.run could not be reached",
     "Your namespace on cyfr.run is your identity on every server, and this server " <>
       "could not reach it to find or claim yours. Nothing was set up. Try again in a moment."}
  end

  defp unavailable_copy(:no_access_token) do
    {"Sign-in incomplete",
     "Your identity provider returned no access token, so cyfr.run could not be asked " <>
       "for your namespace. Nothing was set up. Sign in again."}
  end

  defp unavailable_copy(:namespace_conflict) do
    {"Namespace already in use here",
     "cyfr.run names you by a namespace another identity on this server already holds. " <>
       "Ask the operator to sort it out."}
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
