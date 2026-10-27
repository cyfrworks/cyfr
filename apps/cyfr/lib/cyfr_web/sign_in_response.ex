# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.SignInResponse do
  @moduledoc """
  One transcription of the sign-in outcome to a browser response.

  An admitted sign-in proceeds (`:proceed`); four surfaces render it —
  the Ueberauth callback, the device-flow ticket, the passkey ticket and
  the `cyfr` door's callback — and one more answer, a membership read
  that failed while minting the session, is a page. This module owns the
  one mapping, and the differences that are real travel as options:

    * `:session` — `{:mint, ctx}` (create the session and cookie it) or
      `{:token, token}` (cookie an already-minted token — the device and
      passkey tickets and the `cyfr` door).
    * `:retry_path` — where the 503 page's "Try again" points.
    * `:to` — where a proceeding sign-in goes instead of the post-login
      landing, answered `303`: an absolute URL its caller has already
      verified. Only the `cyfr` door's callback passes one, the fixed
      return URL of the signing home's `/carry` that the carry's envelope
      signed, so the person's browser reports the outcome there.

  Every outcome is a redirect or a page; the session token travels in
  the cookie and nowhere else.
  """

  import Plug.Conn

  require Logger

  @session_key CyfrWeb.ContextGuard.session_key()

  @type outcome :: :proceed | {:unavailable, atom()}

  @doc """
  The Plug session key holding the Sanctum session token. This module is
  the one writer; the spelling is the guard's that reads it on every
  protected mount (`CyfrWeb.ContextGuard.session_key/0`), and every other
  reader takes it from here (LiveView mounts see the session as a
  string-keyed map — `to_string/1` it).
  """
  def session_key, do: @session_key

  @spec respond(Plug.Conn.t(), outcome(), keyword()) :: Plug.Conn.t()
  def respond(conn, outcome, opts)

  def respond(conn, :proceed, opts) do
    established(conn, opts, &landing(&1, Keyword.get(opts, :to)))
  end

  def respond(conn, {:unavailable, reason}, opts) do
    # A mint-path failure leaves no session behind.
    conn =
      case Keyword.fetch!(opts, :session) do
        {:mint, _ctx} -> safe_drop_session(conn)
        _ -> conn
      end

    {title, inner} = unavailable_page(reason, Keyword.get(opts, :retry_path, "/login"))
    refusal_page(conn, 503, title, inner)
  end

  # A sign-in that does not finish is the request's refused decision,
  # recorded once under its title (`CyfrWeb.Plugs.CallIdentity.refused/3`)
  # where the route minted a call identity, and answered as a page.
  defp refusal_page(conn, status, title, inner) do
    conn
    |> CyfrWeb.Plugs.CallIdentity.refused(status, title)
    |> CyfrWeb.MinimalPage.send_page(status, title, inner)
  end

  # The post-login landing, or the verified `:to` its caller named.
  defp landing(conn, nil), do: CyfrWeb.SafeRedirect.post_login(conn)

  defp landing(conn, to) when is_binary(to) do
    conn
    |> put_status(303)
    |> Phoenix.Controller.redirect(external: to)
  end

  # The outage copy, per reason: `{title, message}`.
  defp unavailable_copy(:membership_read) do
    {"Temporarily unavailable",
     "The server could not read memberships just now — a transient fault, " <>
       "not a refusal. Try again in a moment."}
  end

  defp unavailable_copy(_) do
    {"Temporarily unavailable", "Signing in did not finish. Try again in a moment."}
  end

  @doc """
  Put a flash message when the conn has fetched its flash; a conn without
  one is answered unchanged.
  """
  def put_flash_if_available(conn, kind, msg) do
    Phoenix.Controller.put_flash(conn, kind, msg)
  rescue
    # `put_flash/3` raises ArgumentError when no flash was fetched; nothing
    # else is caught.
    ArgumentError -> conn
  end

  @doc "Drop the Plug session; a no-op when none was fetched (API routes)."
  def safe_drop_session(conn) do
    configure_session(conn, drop: true)
  rescue
    ArgumentError -> conn
  end

  # Start the authenticated session on a clean one. Whatever the browser
  # carried while anonymous — most of all Phoenix's `_csrf_token`, which is
  # the value `AuthController.same_browser?/2` binds a device-flow ticket to
  # — must not survive the exchange, or a session an attacker could plant on
  # this origin beforehand keeps its hold afterwards. `clear_session/1` drops
  # the data (the cookie store keeps no id to rotate) and `renew: true` moves
  # the id for a server-side store.
  defp renew_session(conn), do: conn |> configure_session(renew: true) |> clear_session()

  # The session, then the cookie, then whatever the outcome renders. A
  # session that cannot be written is a 500 — the only non-redirect answer
  # a browser sees on an admitted sign-in.
  defp established(conn, opts, fun) do
    case Keyword.fetch!(opts, :session) do
      {:mint, ctx} ->
        case Sanctum.Session.create(ctx) do
          {:ok, session} ->
            fun.(conn |> renew_session() |> put_session(@session_key, session.token))

          # A remote person whose identity could not be confirmed fresh, or
          # a store that could not answer: the sign-in pauses, retryable,
          # never a failure of this server.
          {:error, reason} when reason in [:identity_stale, :unavailable] ->
            refusal_page(
              conn,
              503,
              "Temporarily unavailable",
              "<p>#{CyfrWeb.MinimalPage.h(Prima.Refusal.message(reason))}</p>" <>
                "<p><a href=\"/login\">Back to sign-in</a></p>"
            )

          # What the sign-in stood on went while it ran: the door it came
          # through was retired, by a recovery of the person's keys that the
          # session's fresh read found or by an unlink, or the person's
          # standing changed (`Sanctum.Session.create/2`). A refusal, never
          # a fault of this server: the person signs in again.
          {:error, :unauthenticated} ->
            CyfrWeb.MinimalPage.send_page(
              conn,
              401,
              "Sign-in failed",
              "<p>What this sign-in came through no longer admits you here. " <>
                "Sign in again.</p>" <>
                "<p><a href=\"/login\">Sign in again</a></p>"
            )

          {:error, reason} ->
            Logger.error("[CyfrWeb.SignInResponse] session create failed: #{inspect(reason)}")

            # Render browser sign-in failures as a page.
            refusal_page(
              conn,
              500,
              "Couldn't finish signing in",
              "<p>The session could not be created. Please try again.</p>" <>
                "<p><a href=\"/login\">Back to sign-in</a></p>"
            )
        end

      {:token, token} ->
        fun.(conn |> renew_session() |> put_session(@session_key, token))
    end
  end

  # A sign-in that could not be finished: the shared no-session shell and
  # a way to try again.
  defp unavailable_page(reason, retry_path) do
    {title, message} = unavailable_copy(reason)
    href = CyfrWeb.MinimalPage.h(retry_path)

    {title,
     "<p>#{CyfrWeb.MinimalPage.h(message)}</p>" <>
       "<p><a href=\"#{href}\">Try again</a></p>"}
  end
end
