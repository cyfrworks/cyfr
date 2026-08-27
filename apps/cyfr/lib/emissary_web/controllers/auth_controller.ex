# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.AuthController do
  @moduledoc """
  OAuth authentication controller for CYFR.

  Handles OAuth/OIDC authentication flows.

  GitHub and Google browser sign-in is device flow on `/login`
  (`PrismWeb.LoginLive`). This controller finishes that flow
  (`GET /auth/device/complete/:ticket`) and still runs the Ueberauth
  web-callback path for a configured OIDC issuer (`GET /auth/oidcc`).

  ## Routes

  - `GET /auth/:provider` - OIDC (and leftover web OAuth) kickoff
  - `GET /auth/:provider/callback` - Handles OAuth callback (redirects; the
    session token lives in the cookie, never in a body)
  - `GET /auth/device/complete/:ticket` - Sets the cookie after device flow
  - `GET /auth/post-legal-accept` - Re-probes after policy acceptance
  - `DELETE /auth/logout` - Destroys session
  """

  use EmissaryWeb, :controller

  require Logger

  plug EmissaryWeb.Plugs.ConfiguredUeberauth

  alias EmissaryWeb.SignInResponse
  alias Sanctum.Session

  @doc """
  Initiates OAuth request to provider.

  Ueberauth handles the redirect automatically based on the :provider param.
  """
  def request(conn, _params) do
    # Ueberauth plug handles the redirect; this is the no-strategy branch.
    # A browser pipeline answers in HTML — these arms used to dump JSON
    # into the person's window.
    EmissaryWeb.MinimalPage.send_page(
      conn,
      404,
      "Unknown sign-in provider",
      "<p>This sign-in provider is not configured on this server.</p>" <>
        "<p><a href=\"/login\">Back to sign-in</a></p>"
    )
  end

  @doc """
  Finishes GitHub/Google device-flow sign-in: the LiveView minted a
  one-time ticket after `DeviceFlow.poll_for_session/2` created the
  Sanctum session; this sets the cookie and routes the same way the
  Ueberauth callback does (home, claim, or legal-accept).
  """
  def device_complete(conn, %{"ticket" => ticket})
      when is_binary(ticket) and byte_size(ticket) > 0 and byte_size(ticket) <= 64 do
    key = {:login_device_ticket, ticket}

    case Arca.Cache.get(key) do
      {:ok, payload} ->
        Arca.Cache.invalidate(key)
        apply_device_ticket(conn, payload)

      :miss ->
        conn
        |> SignInResponse.put_flash_if_available(
          :error,
          "That sign-in expired. Please try again."
        )
        |> redirect(to: "/login")
    end
  end

  def device_complete(conn, _params) do
    conn
    |> SignInResponse.put_flash_if_available(:error, "That sign-in expired. Please try again.")
    |> redirect(to: "/login")
  end

  defp apply_device_ticket(conn, %{session_token: token, outcome: outcome} = payload)
       when is_binary(token) do
    # The one outcome→response mapping the callback uses — so the device
    # path's proceed report flashes its warnings here too, instead of
    # silently dropping them as the ticket's :next flag once did.
    SignInResponse.respond(conn, outcome,
      session: {:token, token},
      access_token: payload[:access_token]
    )
  end

  defp apply_device_ticket(conn, _payload) do
    conn
    |> SignInResponse.put_flash_if_available(:error, "That sign-in expired. Please try again.")
    |> redirect(to: "/login")
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
  - IdP token refused → no session, back through `/login`
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
          SignInResponse.respond(conn, {:proceed, report}, session: {:mint, ctx})

        outcome ->
          # The IdP token travels for the claim or the policy acceptance
          # that still needs it; the responder stashes it only on those arms.
          SignInResponse.respond(conn, outcome,
            session: {:mint, ctx},
            access_token: access_token,
            reauth_flash: true
          )
      end
    else
      {:error, {:door, _reason}} ->
        # Refused at the door: no session, no cookie, no cyfr.run call. One
        # message whichever branch refused.
        EmissaryWeb.MinimalPage.send_page(
          conn,
          403,
          "Not allowed on this server",
          "<p>#{EmissaryWeb.MinimalPage.h(Sanctum.Door.refusal_message())}</p>"
        )

      {:error, reason} ->
        EmissaryWeb.MinimalPage.send_page(
          conn,
          401,
          "Sign-in failed",
          "<p>#{EmissaryWeb.MinimalPage.h(friendly_error_message(reason))}</p>" <>
            "<p><a href=\"/login\">Try again</a></p>"
        )
    end
  end

  def callback(%{assigns: %{ueberauth_failure: failure}} = conn, _params) do
    EmissaryWeb.MinimalPage.send_page(
      conn,
      401,
      "Sign-in failed",
      "<p>#{EmissaryWeb.MinimalPage.h(failure_message(failure))}</p>" <>
        "<p><a href=\"/login\">Try again</a></p>"
    )
  end

  def callback(conn, _params) do
    EmissaryWeb.MinimalPage.send_page(
      conn,
      400,
      "Invalid sign-in callback",
      "<p>The sign-in callback carried no auth or failure information.</p>" <>
        "<p><a href=\"/login\">Try again</a></p>"
    )
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
    case PrismWeb.PendingProbe.pop(conn) do
      {:ok, conn, access_token} ->
        do_post_legal_accept(conn, access_token)

      {_missing, conn} ->
        # Cookie expired (10 min TTL) or never set. Force fresh OAuth.
        Logger.info(
          "[EmissaryWeb.AuthController] post_legal_accept: missing probe cookie; " <>
            "redirecting to login"
        )

        conn |> redirect(to: "/login")
    end
  end

  defp do_post_legal_accept(conn, access_token) do
    case get_session(conn, EmissaryWeb.SignInResponse.session_key()) do
      session_token when is_binary(session_token) and session_token != "" ->
        with {:ok, peeked} <- Sanctum.Caller.peek(session_token),
             {:ok, user} <- Sanctum.Tenancy.Users.get(peeked.user_id) do
          provider = peeked.provider || "github"

          case Sanctum.SignIn.complete(user, provider, access_token) do
            {:proceed, _user, report} ->
              SignInResponse.respond(conn, {:proceed, report}, session: :existing)

            {:reauthenticate, _reason} = outcome ->
              SignInResponse.respond(conn, outcome,
                session: :existing,
                teardown: {:destroy_and_drop, session_token}
              )

            outcome ->
              # needs_legal loops back to /legal/accept (a version bump
              # between accept and re-probe); no token travels — the probe
              # cookie already holds it.
              SignInResponse.respond(conn, outcome,
                session: :existing,
                retry_path: "/auth/post-legal-accept"
              )
          end
        else
          _ -> conn |> redirect(to: "/login")
        end

      _ ->
        conn |> redirect(to: "/login")
    end
  end

  # Pulls the IdP access_token from the Ueberauth struct. Both GitHub and
  # Google strategies populate `auth.credentials.token`. A configured OIDC
  # provider (ueberauth_oidcc) also populates it. Nil when absent.
  defp extract_access_token(%{credentials: %{token: token}}) when is_binary(token), do: token
  defp extract_access_token(_), do: nil

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
          |> SignInResponse.safe_drop_session()
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

  defp get_bearer_token(conn), do: Sanctum.BearerToken.read(conn)

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
