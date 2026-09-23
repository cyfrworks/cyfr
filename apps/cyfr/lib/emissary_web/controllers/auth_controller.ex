# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.AuthController do
  @moduledoc """
  OAuth authentication controller for CYFR.

  Handles OAuth/OIDC authentication flows.

  GitHub and Google browser sign-in is device flow on `/login`
  (`PrismWeb.LoginLive`). This controller finishes that flow
  (`GET /auth/device/complete/:ticket`) and runs the Ueberauth callback for a
  configured OIDC issuer (`GET /auth/oidcc`).

  ## Routes

  - `GET /auth/:provider` - OIDC kickoff
  - `GET /auth/:provider/callback` - Handles the OIDC callback (redirects; the
    session token lives in the cookie, never in a body)
  - `GET /auth/device/complete/:ticket` - Sets the cookie after device flow
  - `GET /auth/post-legal-accept` - Re-probes after policy acceptance
  - `DELETE /auth/logout` - Destroys session
  """

  use EmissaryWeb, :controller

  require Logger

  plug EmissaryWeb.Plugs.ConfiguredUeberauth

  alias PrismWeb.SignInResponse
  alias Sanctum.Session

  @doc """
  Answers a sign-in start for a provider this server does not configure.

  `EmissaryWeb.Plugs.ConfiguredUeberauth` redirects a configured OIDC start
  before this action runs.
  """
  def request(conn, _params) do
    # Render the no-strategy branch as HTML; Ueberauth handles configured redirects.
    PrismWeb.MinimalPage.send_page(
      conn,
      404,
      "Unknown sign-in provider",
      "<p>This sign-in provider is not configured on this server.</p>" <>
        "<p><a href=\"/login\">Back to sign-in</a></p>"
    )
  end

  @doc """
  Finishes GitHub/Google device-flow sign-in: the LiveView minted a
  one-time ticket after `DeviceFlow.poll_for_session/3` created the
  Sanctum session; this sets the cookie and routes the same way the
  OIDC callback does (home, claim, or legal-accept).
  """
  def device_complete(conn, %{"ticket" => ticket})
      when is_binary(ticket) and byte_size(ticket) > 0 and byte_size(ticket) <= 64 do
    # Taken in one operation, so of two requests presenting the ticket only
    # one finds it; and consumed whichever way the check goes: a ticket
    # presented by the wrong browser is spent, not left for the right one.
    case Arca.Cache.take({:login_device_ticket, ticket}) do
      {:ok, payload} ->
        if same_browser?(conn, payload) do
          apply_device_ticket(conn, payload)
        else
          Logger.warning(
            "[AuthController] device ticket presented by a different browser than the one " <>
              "that started the flow — refusing"
          )

          conn
          |> SignInResponse.put_flash_if_available(
            :error,
            "That sign-in link was started in a different browser. Please sign in again."
          )
          |> redirect(to: "/login")
        end

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

  # The ticket names the browser that minted it (LoginLive binds the
  # session's CSRF token). Anything else — including a ticket minted before
  # this check existed, or a session with no token to compare — is refused:
  # an unbound ticket is a bearer credential for someone's whole session.
  defp same_browser?(conn, %{browser_binding: binding}) when is_binary(binding) do
    case get_session(conn, "_csrf_token") do
      current when is_binary(current) and current != "" ->
        Plug.Crypto.secure_compare(current, binding)

      _ ->
        false
    end
  end

  defp same_browser?(_conn, _payload), do: false

  defp apply_device_ticket(conn, %{session_token: token, outcome: outcome} = payload)
       when is_binary(token) do
    # Render the sign-in outcome and any warnings, including device flow.
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
  Handles the OIDC callback from the issuer — the browser sign-in.

  Door → what sign-in records → the registry courtesy
  (`Sanctum.SignIn.complete/3`) → a session and a redirect. Every outcome
  is a redirect or a page; the session token travels in the cookie and
  nowhere else.

  - admitted → session, cookie, `/` (the IdP token rides in the probe
    cookie for ten minutes when a publisher namespace is still theirs to
    claim)
  - a membership read failed while minting → no session, a page saying so
  - refused at the door → 403 page, no session, no cyfr.run call
  """
  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    access_token = extract_access_token(auth)
    provider = auth.provider

    with {:ok, ctx} <- authenticate_with_provider(auth),
         {:ok, ctx, user} <- admit(ctx, auth) do
      {:proceed, user, report} =
        Compendium.SignInSync.complete(ctx, user, provider, access_token)

      # The athanor may have been minted a moment ago: resolve again so the
      # session names it. A failed read here answers 503 with no session —
      # not a session whose tenant gate 403s every request.
      case Sanctum.Tenancy.resolve_status(%{ctx | namespace: user.namespace}, force: true) do
        {:ok, ctx} ->
          SignInResponse.respond(conn, {:proceed, report},
            session: {:mint, ctx},
            access_token: if(is_nil(user.namespace), do: access_token)
          )

        {:error, :unavailable} ->
          SignInResponse.respond(conn, {:unavailable, :membership_read},
            session: {:mint, ctx},
            retry_path: "/login"
          )
      end
    else
      {:error, {:door, _reason}} ->
        # Refused at the door: no session, no cookie, no cyfr.run call. One
        # message whichever branch refused.
        PrismWeb.MinimalPage.send_page(
          conn,
          403,
          "Not allowed on this server",
          "<p>#{PrismWeb.MinimalPage.h(Sanctum.Door.refusal_message())}</p>"
        )

      {:error, :unavailable} ->
        # A transient membership read during authenticate — a 503, never a
        # 401: the person's credentials were fine and retrying fixes it.
        PrismWeb.MinimalPage.send_page(
          conn,
          503,
          "Temporarily unavailable",
          "<p>The server could not read memberships just now. " <>
            "This is a transient fault, not a refusal.</p>" <>
            "<p><a href=\"/login\">Try again</a></p>"
        )

      {:error, reason} ->
        PrismWeb.MinimalPage.send_page(
          conn,
          401,
          "Sign-in failed",
          "<p>#{PrismWeb.MinimalPage.h(friendly_error_message(reason))}</p>" <>
            "<p><a href=\"/login\">Try again</a></p>"
        )
    end
  end

  def callback(%{assigns: %{ueberauth_failure: failure}} = conn, _params) do
    PrismWeb.MinimalPage.send_page(
      conn,
      401,
      "Sign-in failed",
      "<p>#{PrismWeb.MinimalPage.h(failure_message(failure))}</p>" <>
        "<p><a href=\"/login\">Try again</a></p>"
    )
  end

  def callback(conn, _params) do
    PrismWeb.MinimalPage.send_page(
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
  `_cyfr_pending_probe`): the same courtesy as the callback, from a session
  that already exists.

  Closes the loop:
    probe → policy required → /legal/accept → /auth/post-legal-accept → probe → ok
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

  # The probe writes on the person's row, so it runs only for a session that
  # stands now: established, then revalidated against the stored session
  # and the person's standing — never a look at who the cookie names.
  defp do_post_legal_accept(conn, access_token) do
    session_token = get_session(conn, PrismWeb.SignInResponse.session_key())

    with {:ok, ctx} <- Sanctum.Caller.establish(session_token, refresh: false),
         {:ok, ctx} <- Sanctum.Caller.revalidate_session(ctx),
         {:ok, user} <- Sanctum.Tenancy.Users.get(ctx.user_id) do
      provider = ctx.provider || "github"

      {:proceed, user, report} =
        Compendium.SignInSync.complete(ctx, user, provider, access_token)

      # The token stays for the claim that may follow the acceptance.
      SignInResponse.respond(conn, {:proceed, report},
        session: :existing,
        access_token: if(is_nil(user.namespace), do: access_token)
      )
    else
      {:error, :unavailable} ->
        PrismWeb.MinimalPage.send_page(
          conn,
          503,
          "Try again shortly",
          "<p>We could not confirm your session just now.</p>" <>
            "<p><a href=\"/login\">Sign in again</a></p>"
        )

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

  Accepts the credential only from the `Authorization: Bearer` header.
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
          EmissaryWeb.ApiError.send(conn, 500, :logout_failed, friendly_error_message(reason))
      end
    else
      EmissaryWeb.ApiError.send(conn, 400, :missing_token, "No session token provided")
    end
  end

  @doc """
  Returns current session info.

  Requires Authorization: Bearer {token} header.
  """
  def whoami(conn, _params) do
    case get_bearer_token(conn) do
      nil ->
        EmissaryWeb.ApiError.send(conn, 401, :auth_required, "No session token provided")

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
            EmissaryWeb.ApiError.send(conn, 401, :invalid_session, "Invalid session token")
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

    # The provider's context names the person by their IdP identity key;
    # from admission on they are named by their own id.
    with {:ok, verdict} <- Sanctum.Door.admit_identity(ctx.user_id, user_info),
         {:ok, user} <- Sanctum.SignIn.admitted(user_info, verdict) do
      # The context is renamed to the person's own id and nothing else: an
      # athanor pinned here is the one every later resolve keeps, and the
      # mint is what decides which. The callback resolves after it.
      {:ok, %{ctx | user_id: user.id}, user}
    end
  end

  # The IdP screen name, persisted on the person's row.
  defp screen_name(%{info: info}) when is_map(info) do
    Map.get(info, :name) || Map.get(info, :nickname)
  end

  defp screen_name(_), do: nil

  defp authenticate_with_provider(auth) do
    # Dispatch to the configured provider; only `Sanctum.Auth.OIDC` accepts a
    # callback.
    case Cyfr.RuntimeConfig.auth_provider() do
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

  # The server is at capacity: a real refusal with a cause the person can
  # act on (wait, or ask the operator), not an unhandled term.
  defp friendly_error_message({:limit_reached, :mint_per_hour, _cap}),
    do: "This server is admitting new people slowly right now. Please try again shortly."

  defp friendly_error_message({:limit_reached, _key, _cap}),
    do: "This server is full and cannot make you an athanor. Ask its operator for room."

  defp friendly_error_message(:email_not_verified),
    do: "Your provider reported an unverified email. Please verify your email and try again."

  defp friendly_error_message(:missing_email),
    do:
      "Your provider did not return an email address. Please check your account privacy settings and try again."

  defp friendly_error_message({:validation_error, _}), do: "Invalid authentication data"
  defp friendly_error_message({:provider_error, _}), do: "Authentication provider error"

  defp friendly_error_message(reason) do
    Logger.warning("[AuthController] Unhandled auth error: #{inspect(reason)}")
    "An error occurred during authentication"
  end
end
