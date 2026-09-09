# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SignInResponse do
  @moduledoc """
  One transcription of the sign-in outcome to a browser response.

  `Sanctum.SignIn.complete/3` always proceeds; three surfaces render it —
  the Ueberauth callback, the device-flow ticket, and the post-legal
  re-probe — and one more answer, a membership read that failed while
  minting the session, is a page. This module owns the one mapping, and
  the differences that are real travel as options:

    * `:session` — `{:mint, ctx}` (create the session and cookie it),
      `{:token, token}` (cookie an already-minted token — the device
      ticket), or `:existing` (the cookie session stands — post-legal).
    * `:access_token` — keep the IdP token in the `_cyfr_pending_probe`
      cookie for a person who still has a publisher namespace to claim;
      absent retires any stash.
    * `:retry_path` — where the 503 page's "Try again" points.

  Every outcome is a redirect or a page; the session token travels in
  the cookie and nowhere else.
  """

  import Plug.Conn

  require Logger

  @probe_cookie PrismWeb.PendingProbe.cookie_name()
  @session_key :sanctum_session_token

  @type outcome :: {:proceed, map()} | {:unavailable, atom()}

  @doc """
  The Plug session key holding the Sanctum session token. This module is
  the one writer; every reader takes the spelling from here (LiveView
  mounts see the session as a string-keyed map — `to_string/1` it).
  """
  def session_key, do: @session_key

  @spec respond(Plug.Conn.t(), outcome(), keyword()) :: Plug.Conn.t()
  def respond(conn, outcome, opts)

  def respond(conn, {:proceed, report}, opts) do
    established(conn, opts, fn conn ->
      conn
      |> carry_or_retire_probe(opts)
      |> flash_report(report)
      |> PrismWeb.SafeRedirect.post_login()
    end)
  end

  def respond(conn, {:unavailable, reason}, opts) do
    # A mint-path failure leaves no session behind; an existing session
    # (post-legal) stands so the person can retry from it.
    conn =
      case Keyword.fetch!(opts, :session) do
        {:mint, _ctx} -> safe_drop_session(conn)
        _ -> conn
      end

    {title, inner} = unavailable_page(reason, Keyword.get(opts, :retry_path, "/login"))
    PrismWeb.MinimalPage.send_page(conn, 503, title, inner)
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
  Put a flash message only if flash is available on the conn — some test
  paths exercise these responses without the full browser plug stack.
  """
  def put_flash_if_available(conn, kind, msg) do
    Phoenix.Controller.put_flash(conn, kind, msg)
  rescue
    # Narrowed to the one thing this is for — `put_flash/3` raises
    # ArgumentError when no session was fetched. A bare `_` here caught
    # genuine bugs too and returned the conn as if nothing had happened,
    # three lines above a sibling that gets this right.
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
  # the id for a server-side store. Everything this module writes for the
  # claim and legal pages is written after, inside the outcome's callback.
  defp renew_session(conn) do
    conn |> configure_session(renew: true) |> clear_session()
  rescue
    ArgumentError -> conn
  end

  # The session, then the cookie, then whatever the outcome renders. A
  # session that cannot be written is a 500 — the only non-redirect answer
  # a browser sees on an admitted sign-in.
  defp established(conn, opts, fun) do
    case Keyword.fetch!(opts, :session) do
      {:mint, ctx} ->
        case Sanctum.Session.create(ctx) do
          {:ok, session} ->
            fun.(conn |> renew_session() |> put_session(@session_key, session.token))

          {:error, reason} ->
            Logger.error("[PrismWeb.SignInResponse] session create failed: #{inspect(reason)}")

            # Render browser sign-in failures as a page.
            PrismWeb.MinimalPage.send_page(
              conn,
              500,
              "Couldn't finish signing in",
              "<p>The session could not be created. Please try again.</p>" <>
                "<p><a href=\"/login\">Back to sign-in</a></p>"
            )
        end

      {:token, token} ->
        fun.(conn |> renew_session() |> put_session(@session_key, token))

      :existing ->
        fun.(conn)
    end
  end

  # The IdP token is kept only for a person who still has a publisher
  # namespace to claim; any other sign-in retires a stale stash.
  defp carry_or_retire_probe(conn, opts) do
    case Keyword.get(opts, :access_token) do
      token when is_binary(token) and token != "" -> stash_pending_probe(conn, token)
      _ -> delete_resp_cookie(conn, @probe_cookie)
    end
  end

  # 10-min encrypted cookie holding the IdP access_token for the one thing
  # that still needs it: the claim submission, or the re-probe after legal
  # acceptance. Not stored in the session DB (secret sprawl). Guarded
  # against a missing secret_key_base (some test-only conn paths) — the
  # cookie is what makes the claim possible, and its absence is logged.
  defp stash_pending_probe(conn, access_token) when is_binary(access_token) do
    try do
      put_resp_cookie(conn, @probe_cookie, access_token,
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
          "[PrismWeb.SignInResponse] failed to stash pending_probe cookie: #{Exception.message(e)}"
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

      :legal_required ->
        put_flash_if_available(
          conn,
          :info,
          "cyfr.run has updated its policy — you're signed in; publishing will ask you to accept it."
        )

      :namespace_conflict ->
        put_flash_if_available(
          conn,
          :error,
          "cyfr.run names you by a namespace another identity on this server holds — " <>
            "you're signed in; ask the operator to sort it out before publishing."
        )

      _ ->
        conn
    end
  end

  defp flash_report(conn, _report), do: conn

  # A sign-in that could not be finished: the shared no-session shell and
  # a way to try again.
  defp unavailable_page(reason, retry_path) do
    {title, message} = unavailable_copy(reason)
    href = PrismWeb.MinimalPage.h(retry_path)

    {title,
     "<p>#{PrismWeb.MinimalPage.h(message)}</p>" <>
       "<p><a href=\"#{href}\">Try again</a></p>"}
  end
end
