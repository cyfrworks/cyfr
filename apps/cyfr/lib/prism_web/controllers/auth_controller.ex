# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AuthController do
  @moduledoc """
  Browser sign-in and sign-out for CYFR.

  Handles the browser's OAuth/OIDC authentication flows.

  GitHub and Google browser sign-in is device flow on `/login`
  (`PrismWeb.LoginLive`). This controller finishes that flow
  (`GET /auth/device/complete/:ticket`) and runs the Ueberauth callback for a
  configured OIDC issuer (`GET /auth/oidcc`).

  ## Routes

  - `GET /auth/:provider` - OIDC kickoff
  - `GET /auth/:provider/callback` - Handles the OIDC callback (redirects; the
    session token lives in the cookie, never in a body)
  - `GET /auth/device/complete/:ticket` - Sets the cookie after device flow
  - `POST /auth/logout` - Browser sign-out (cookie session, forgery-guarded)
  - `POST /auth/link/oidcc` - Begins linking an OpenID Connect door to the
    person signed in
  - `GET /auth/cyfr/start?ticket=…` - A `cyfr` sign-in begun from a handle
  - `GET /auth/cyfr?ticket=…` - The `cyfr` door's challenge hop
  - `POST /auth/cyfr/callback` - The `cyfr` door's callback

  An API caller's sign-out and session read, by bearer token, are the
  HTTP API's, not the browser's.

  ## The `cyfr` door

  A person whose keys another home holds signs in with an assertion their
  home signs (`Sanctum.Auth.CyfrDoor`). A sign-in begun from a handle
  starts here: the sign-in page resolved the handle (`Sanctum.Handle`)
  and hands the answer over by a one-time ticket bound to the browser's
  CSRF token (`GET /auth/cyfr/start?ticket=…`), which holds the
  identifier the handle named, the published address's origin and that
  home's `/carry` (`Sanctum.Auth.CyfrDoor.signing_home/1`). This action
  keeps the request, `{identifier, home, expires_at}` for the carry's
  lifetime, in the browser's own session cookie (`cyfr_request_key/0`)
  and answers `303` to that `/carry`. The sign-in page reads the request
  back when the carry returns and holds the carry to its identifier, and
  the callback drops it once it admits. The sign-in page verifies the
  carry their browser brought, mints this home's challenge and hands it
  here by a one-time ticket bound to the browser's CSRF token
  (`GET /auth/cyfr?ticket=…`). This action keeps the challenge in the
  browser's own session cookie (`cyfr_challenge_key/0`) and answers
  `303` to the carry's signed return URL, the person's home's `/carry`,
  with the challenge in its fragment; it redirects nowhere the carry does
  not sign. The person's home sends the browser back to `/login` with the
  assertion in a fragment, and the sign-in page posts it here, with its
  CSRF token, since a fragment never reaches a server
  (`POST /auth/cyfr/callback`). The callback admits under the challenge
  the cookie holds, or resumes the session an earlier admission under it
  minted, and sets the session as every sign-in does.

  Then it sends the browser back to the person's home to report how the
  sign-in ended (`Prima.Carry.Return`): an admitted one answers `303` to
  that home's `/carry` with `admitted` in the fragment, and a refused one's
  page links there with `refused`. The address is only the fixed return
  URL of the source the carry's envelope signed
  (`Prima.Carry.return_url/1` of the held challenge's `source`, verified
  when the challenge was issued), never one the request names. A paused
  sign-in (the directory could not be read) reports nothing: it may still
  be admitted on a retry.

  ## Linking a door

  `POST /auth/link/oidcc`, under the browser's session and its forgery
  token, holds a link intent in the cookie session (the person, their
  session's token hash and a return path `CyfrWeb.SafeRedirect.link_return/1`
  admits) for ten minutes and starts the issuer's sign-in. The callback
  that finds the intent signs no one in: it takes the intent, holds the
  issuer's identity to the session that asked, still standing, and hands
  it to `Sanctum.SignIn.link_ticket/2`, which asks the door. The ticket
  goes into the cookie session under `link_ticket_key/0`, as
  `%{"provider" => "oidcc", "ticket" => ticket}`, never into a URL, and
  the browser returns to the page that asked, which presents it to
  `person.link_door`.
  """

  use PrismWeb, :controller

  require Logger

  plug CyfrWeb.Plugs.ConfiguredUeberauth

  alias CyfrWeb.Plugs.CallIdentity
  alias CyfrWeb.SignInResponse
  alias Sanctum.Session

  @link_intent "cyfr_link_intent"
  @link_ticket "cyfr_link_ticket"
  @link_intent_ms 600_000
  @cyfr_challenge "cyfr_challenge"
  @cyfr_request "cyfr_request"

  @doc """
  The cookie session key the `cyfr` door's challenge is held under between
  its hop and its callback (the module doc).
  """
  @spec cyfr_challenge_key() :: String.t()
  def cyfr_challenge_key, do: @cyfr_challenge

  @doc """
  The cookie session key a `cyfr` sign-in begun from a handle keeps its
  request under, `%{"identifier", "home", "expires_at"}` (Unix
  milliseconds), between its start and its callback (the module doc).
  """
  @spec cyfr_request_key() :: String.t()
  def cyfr_request_key, do: @cyfr_request

  @doc """
  The cookie session key the link ticket an OpenID Connect sign-in minted
  is held under, as `%{"provider" => "oidcc", "ticket" => ticket}`: what
  the page that started the link reads and presents to `person.link_door`.
  """
  @spec link_ticket_key() :: String.t()
  def link_ticket_key, do: @link_ticket

  @doc """
  Begin linking an OpenID Connect door to the person this browser's
  session names (the module doc): `POST /auth/link/oidcc`, `return_to`
  being the settings page to come back to.
  """
  def link_start(conn, params) do
    case standing_session(conn) do
      {:ok, ctx} ->
        intent = %{
          "user_id" => ctx.user_id,
          "session" => Base.url_encode64(ctx.session_token_hash, padding: false),
          "return_to" => CyfrWeb.SafeRedirect.link_return(params["return_to"]),
          "expires_at" => System.system_time(:millisecond) + @link_intent_ms
        }

        conn
        |> delete_session(@link_ticket)
        |> put_session(@link_intent, intent)
        |> redirect(to: "/auth/oidcc")

      {:error, _no_session} ->
        to_login(conn, 401, "Sign in, then link the sign-in method again.")
    end
  end

  @doc """
  Answers a sign-in start for a provider this server does not configure,
  and the `cyfr` door's challenge hop (the module doc).

  `CyfrWeb.Plugs.ConfiguredUeberauth` redirects a configured OIDC start
  before this action runs.
  """
  def request(conn, %{"provider" => "cyfr", "ticket" => ticket})
      when is_binary(ticket) and byte_size(ticket) > 0 and byte_size(ticket) <= 64 do
    # Taken in one operation and consumed whichever way the check goes, as
    # a device-flow ticket is: a ticket another browser presents is spent.
    case Arca.Cache.take({:login_cyfr_ticket, ticket}) do
      {:ok, %{held: held} = payload} ->
        if same_browser?(conn, payload) do
          conn
          |> put_session(@cyfr_challenge, held)
          |> put_status(303)
          |> redirect(external: Sanctum.Auth.CyfrDoor.redirect_url(held))
        else
          Logger.warning(
            "[AuthController] cyfr sign-in ticket presented by a different browser than the " <>
              "one that started it — refusing"
          )

          to_login(
            conn,
            403,
            "That sign-in was started in a different browser. Please sign in again."
          )
        end

      _miss ->
        cyfr_expired(conn)
    end
  end

  def request(conn, %{"provider" => "cyfr"}), do: cyfr_expired(conn)

  def request(conn, _params) do
    # Render the no-strategy branch as HTML; Ueberauth handles configured redirects.
    page(
      conn,
      404,
      "Unknown sign-in provider",
      "<p>This sign-in provider is not configured on this server.</p>" <>
        "<p><a href=\"/login\">Back to sign-in</a></p>"
    )
  end

  @doc """
  The start of a `cyfr` sign-in begun from a handle (the module doc):
  the request the ticket holds is kept in this browser's session, and the
  browser goes to the published address's `/carry`.
  """
  def cyfr_start(conn, %{"ticket" => ticket})
      when is_binary(ticket) and byte_size(ticket) > 0 and byte_size(ticket) <= 64 do
    # Taken in one operation and consumed whichever way the check goes, as
    # the challenge hop's ticket is.
    case Arca.Cache.take({:login_cyfr_start, ticket}) do
      {:ok, %{identifier: identifier, home: home, to: to} = payload} ->
        if same_browser?(conn, payload) do
          request = %{
            "identifier" => identifier,
            "home" => home,
            "expires_at" =>
              System.os_time(:millisecond) + Sanctum.Auth.CyfrDoor.carry_lifetime_ms()
          }

          conn
          |> put_session(@cyfr_request, request)
          |> put_status(303)
          |> redirect(external: to)
        else
          Logger.warning(
            "[AuthController] cyfr sign-in start presented by a different browser than the " <>
              "one that started it — refusing"
          )

          to_login(
            conn,
            403,
            "That sign-in was started in a different browser. Please sign in again."
          )
        end

      _miss ->
        cyfr_expired(conn)
    end
  end

  def cyfr_start(conn, _params), do: cyfr_expired(conn)

  @doc """
  Finishes GitHub/Google device-flow sign-in: the LiveView minted a
  one-time ticket after `DeviceFlow.poll_for_session/3` created the
  Sanctum session; this sets the cookie and routes the same way the
  OIDC callback does.
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

          to_login(
            conn,
            403,
            "That sign-in link was started in a different browser. Please sign in again."
          )
        end

      :miss ->
        to_login(conn, 404, "That sign-in expired. Please try again.")
    end
  end

  def device_complete(conn, _params) do
    to_login(conn, 404, "That sign-in expired. Please try again.")
  end

  @doc """
  The `cyfr` door's callback (the module doc): the assertion the sign-in
  page posts, admitted, or resumed, under the challenge this browser's
  session cookie holds. An admitted sign-in drops the challenge and any
  request a handle began, sets the session as every sign-in does, then
  goes back to the person's home with `admitted`; a refused one's page
  links back there with `refused` (the module doc).
  """
  def cyfr_callback(conn, %{"fragment" => fragment}) when is_binary(fragment) do
    held = get_session(conn, @cyfr_challenge)

    case Sanctum.Auth.CyfrDoor.callback(fragment, held) do
      {:ok, %{session_token: token}} ->
        conn
        |> delete_session(@cyfr_challenge)
        |> delete_session(@cyfr_request)
        |> SignInResponse.respond(:proceed,
          session: {:token, token},
          to: carry_return(held, :admitted)
        )

      {:error, {:door, _reason}} ->
        page(
          conn,
          403,
          "Not allowed on this server",
          "<p>#{CyfrWeb.MinimalPage.h(Sanctum.Door.refusal_message())}</p>" <>
            back_home(held)
        )

      {:error, reason} when reason in [:identity_stale, :unavailable] ->
        page(
          conn,
          503,
          "Try again shortly",
          "<p>Your identity could not be confirmed with its directory just now. " <>
            "Try again in a moment.</p><p><a href=\"/login\">Back to sign-in</a></p>"
        )

      {:error, reason} ->
        Logger.info(
          "[AuthController] a cyfr sign-in was refused: " <> Prima.LoggerContext.shape(reason)
        )

        page(
          conn,
          401,
          "Sign-in failed",
          "<p>That sign-in could not be completed here. Begin it again from your CYFR.</p>" <>
            refused_return(reason, held) <> "<p><a href=\"/login\">Back to sign-in</a></p>"
        )
    end
  end

  def cyfr_callback(conn, _params), do: cyfr_expired(conn)

  # A retried login whose session has since ended, or another browser's or
  # another assertion's under a challenge already admitted, was admitted
  # once: its home recorded that, and is told nothing else.
  defp refused_return(reason, _held) when reason in [:session_ended, :receipt_conflict], do: ""
  defp refused_return(_reason, held), do: back_home(held)

  # Where the person's browser reports how this sign-in ended: the fixed
  # return URL (`Prima.Carry.return_url/1`) of the source the carry's
  # envelope signed, which `Sanctum.Auth.CyfrDoor.challenge/2` verified
  # before this home held the challenge, with the outcome in its fragment.
  # Never a URL the request carries; nil for a browser holding no
  # challenge.
  defp carry_return(%{"source" => source, "action_id" => action_id}, outcome)
       when is_binary(source) and is_binary(action_id) do
    with true <- Prima.Identity.Encoding.home?(source),
         {:ok, return} <- Prima.Carry.Return.new(action_id, outcome) do
      Prima.Carry.return_url(source) <> "#" <> Prima.Carry.Return.fragment(return)
    else
      _malformed -> nil
    end
  end

  defp carry_return(_held, _outcome), do: nil

  defp back_home(held) do
    case carry_return(held, :refused) do
      nil -> ""
      url -> "<p><a href=\"#{CyfrWeb.MinimalPage.h(url)}\">Back to Aqua</a></p>"
    end
  end

  defp cyfr_expired(conn) do
    to_login(conn, 404, "That sign-in expired. Please try again.")
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

  defp apply_device_ticket(conn, %{session_token: token}) when is_binary(token) do
    SignInResponse.respond(conn, :proceed, session: {:token, token})
  end

  defp apply_device_ticket(conn, _payload) do
    to_login(conn, 404, "That sign-in expired. Please try again.")
  end

  @doc """
  Handles the OIDC callback from the issuer — the browser sign-in.

  The unlock (`Sanctum.SignIn.unlock/1`: the person who linked the
  identity, asked about by the door) → a session and a redirect. Every outcome is a redirect or a page; the session token
  travels in the cookie and nowhere else, and the provider's token goes
  nowhere: no sign-in speaks to the registry.

  - unlocked → session, cookie, `/`
  - a membership read failed → no session, a page saying so
  - no person here linked the identity → 403 page saying how to link it,
    no session
  - refused at the door → 403 page, no session

  A callback that finds a link intent in the cookie session links a door
  instead and signs no one in (the module doc).
  """
  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    case take_link_intent(conn) do
      {conn, nil} -> sign_in(conn, auth)
      {conn, intent} -> link(conn, auth, intent)
    end
  end

  def callback(%{assigns: %{ueberauth_failure: failure}} = conn, _params) do
    {conn, _intent} = take_link_intent(conn)

    page(
      conn,
      401,
      "Sign-in failed",
      "<p>#{CyfrWeb.MinimalPage.h(failure_message(failure))}</p>" <>
        "<p><a href=\"/login\">Try again</a></p>"
    )
  end

  def callback(conn, _params) do
    page(
      conn,
      400,
      "Invalid sign-in callback",
      "<p>The sign-in callback carried no auth or failure information.</p>" <>
        "<p><a href=\"/login\">Try again</a></p>"
    )
  end

  # Link mode: the issuer's identity, held to the session that asked and
  # still standing, becomes a link ticket. No person is minted and no
  # session issued.
  defp link(conn, auth, intent) do
    with {:ok, identity_ctx} <- authenticate_with_provider(auth),
         {:ok, standing} <- standing_session(conn, intent),
         {:ok, ticket} <-
           Sanctum.SignIn.link_ticket(standing, %{
             key: identity_ctx.user_id,
             provider: to_string(Map.get(auth, :provider)),
             email: identity_ctx.email,
             verified: Sanctum.Auth.OIDC.email_verified(auth)
           }) do
      conn
      |> put_session(@link_ticket, %{"provider" => "oidcc", "ticket" => ticket})
      |> redirect(to: intent["return_to"])
    else
      {:error, :unavailable} ->
        page(
          conn,
          503,
          "Temporarily unavailable",
          "<p>The sign-in method could not be linked just now. Try again shortly.</p>"
        )

      {:error, _refused} ->
        page(
          conn,
          401,
          "The sign-in method was not linked",
          "<p>That sign-in could not be linked to you here. Sign in again and link it " <>
            "from your settings.</p>"
        )
    end
  end

  # The intent, taken once whatever follows, and only while it is alive.
  defp take_link_intent(conn) do
    case get_session(conn, @link_intent) do
      %{"expires_at" => expires_at} = intent when is_integer(expires_at) ->
        conn = delete_session(conn, @link_intent)

        if expires_at > System.system_time(:millisecond),
          do: {conn, intent},
          else: {conn, %{"expired" => true}}

      nil ->
        {conn, nil}

      _malformed ->
        {delete_session(conn, @link_intent), %{"expired" => true}}
    end
  end

  # The browser's own session, established and read again: a link belongs
  # to a person who stands, signed in through a stored session.
  defp standing_session(conn) do
    token = get_session(conn, SignInResponse.session_key())

    with {:ok, ctx} <- Sanctum.Caller.establish(token, refresh: false),
         {:ok, %Sanctum.Context{session_token_hash: hash} = ctx} when is_binary(hash) <-
           Sanctum.Caller.revalidate_session(ctx) do
      {:ok, ctx}
    else
      {:error, reason} -> {:error, reason}
      _no_session -> {:error, :unauthenticated}
    end
  end

  defp standing_session(conn, %{"user_id" => user_id, "session" => session}) do
    with {:ok, ctx} <- standing_session(conn),
         true <- ctx.user_id == user_id,
         true <-
           Plug.Crypto.secure_compare(
             Base.url_encode64(ctx.session_token_hash, padding: false),
             session
           ) do
      {:ok, ctx}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :another_session}
    end
  end

  defp standing_session(_conn, _expired), do: {:error, :expired}

  defp sign_in(conn, auth) do
    with {:ok, ctx} <- authenticate_with_provider(auth),
         {:ok, ctx, user} <- unlock(ctx, auth) do
      # The athanor may have been minted a moment ago: resolve again so the
      # session names it. A failed read here answers 503 with no session —
      # not a session whose tenant gate 403s every request.
      case Sanctum.Tenancy.resolve_status(%{ctx | namespace: user.namespace}, force: true) do
        {:ok, ctx} ->
          SignInResponse.respond(conn, :proceed, session: {:mint, ctx})

        {:error, :unavailable} ->
          SignInResponse.respond(conn, {:unavailable, :membership_read},
            session: {:mint, ctx},
            retry_path: "/login"
          )
      end
    else
      {:error, :no_person} ->
        page(
          conn,
          403,
          "No one here signs in with this account",
          "<p>#{CyfrWeb.MinimalPage.h(Prima.Refusal.message(:no_person))}</p>" <>
            "<p><a href=\"/login\">Sign in another way</a></p>"
        )

      {:error, {:door, _reason}} ->
        # Refused at the door: no session, no cookie. One message whichever
        # branch refused.
        page(
          conn,
          403,
          "Not allowed on this server",
          "<p>#{CyfrWeb.MinimalPage.h(Sanctum.Door.refusal_message())}</p>"
        )

      {:error, :unavailable} ->
        # A transient membership read during authenticate — a 503, never a
        # 401: the person's credentials were fine and retrying fixes it.
        page(
          conn,
          503,
          "Temporarily unavailable",
          "<p>The server could not read memberships just now. " <>
            "This is a transient fault, not a refusal.</p>" <>
            "<p><a href=\"/login\">Try again</a></p>"
        )

      {:error, reason} ->
        page(
          conn,
          401,
          "Sign-in failed",
          "<p>#{CyfrWeb.MinimalPage.h(friendly_error_message(reason))}</p>" <>
            "<p><a href=\"/login\">Try again</a></p>"
        )
    end
  end

  @doc """
  The browser's sign-out (`POST /auth/logout`): retires the Sanctum
  session the cookie names, drops the cookie session, and lands on the
  sign-in page.

  POST, never GET, so signing someone out is not one `<img src>` away:
  the route's browser pipeline checks the forgery token first.
  """
  def browser_logout(conn, _params) do
    case get_session(conn, SignInResponse.session_key()) do
      token when is_binary(token) and token != "" -> Session.destroy(token)
      _ -> :ok
    end

    conn
    |> configure_session(drop: true)
    |> redirect(to: "/login?error=signed_out")
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Sign-in establishes a person's sign-in rather than acting under a
  # context the gate admitted, so it decides for itself: every refusal this
  # controller answers, a page with an error status or a flash back to the
  # sign-in page, is the request's refused decision, recorded once under
  # its sentence with no person or athanor
  # (`CyfrWeb.Plugs.CallIdentity.refused/3`).
  defp page(conn, status, title, inner) do
    conn
    |> CallIdentity.refused(status, title)
    |> CyfrWeb.MinimalPage.send_page(status, title, inner)
  end

  defp to_login(conn, status, message) do
    conn
    |> CallIdentity.refused(status, message)
    |> SignInResponse.put_flash_if_available(:error, message)
    |> redirect(to: "/login")
  end

  # The unlock, before any session exists. It runs here, at the one place
  # the web flow mints a session, so no sign-in method can step around it.
  # What the issuer proved about the email decides only whether it is
  # written to the person's contact email.
  defp unlock(%Sanctum.Context{} = ctx, auth) do
    method = %{
      id: ctx.user_id,
      provider: ctx.provider || to_string(Map.get(auth, :provider)),
      email: ctx.email,
      verified: Sanctum.Auth.OIDC.email_verified(auth),
      name: screen_name(auth)
    }

    # The provider's context names the person by their IdP identity key;
    # from the unlock on they are named by their own id.
    with {:ok, user} <- Sanctum.SignIn.unlock(method) do
      # The context is renamed to the person's own id and nothing else: the
      # callback resolves the athanor after it.
      {:ok, %{ctx | user_id: user.id}, user}
    end
  end

  # The IdP screen name, persisted on the person's row.
  defp screen_name(%{info: info}) when is_map(info) do
    Map.get(info, :name) || Map.get(info, :nickname)
  end

  defp screen_name(_), do: nil

  # The one sign-in method with a browser callback: the OpenID Connect
  # issuer, when this CYFR is configured with one.
  defp authenticate_with_provider(auth) do
    if Sanctum.Auth.OIDC.issuer(),
      do: Sanctum.Auth.OIDC.authenticate(auth),
      else: {:error, :auth_provider_not_configured}
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

  # The sign-in page's own words for the refusals the OpenID Connect
  # callback answers before the unlock.
  defp friendly_error_message(:auth_provider_not_configured),
    do: "This CYFR offers no OpenID Connect sign-in"

  defp friendly_error_message(:invalid_credentials),
    do: "The sign-in carried no identity"
end
