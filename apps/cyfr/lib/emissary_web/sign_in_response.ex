# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.SignInResponse do
  @moduledoc """
  One transcription of the sign-in outcome to a browser response.

  `Sanctum.SignIn.complete/3` answers five arms; three surfaces render
  them — the Ueberauth callback, the device-flow ticket, and the
  post-legal re-probe. Each used to keep its own case block, hand-synced
  with the others. This module owns the one mapping, and the differences
  that are real travel as options:

    * `:session` — `{:mint, ctx}` (create the session and cookie it),
      `{:token, token}` (cookie an already-minted token — the device
      ticket), or `:existing` (the cookie session stands — post-legal).
    * `:access_token` — stash the `_cyfr_pending_probe` cookie on
      needs_legal / needs_claim; absent means no stash (post-legal
      already holds the cookie).
    * `:retry_path` — where the 503 page's "Try again" points.
    * `:teardown` — `:drop` (default) clears the Plug session on
      reauthenticate; `{:destroy_and_drop, token}` also retires the
      Sanctum session row and the probe cookie.
    * `:reauth_flash` — flash the reauthenticate reason (the callback
      does; the post-legal path never did).

  Every outcome is a redirect or a page; the session token travels in
  the cookie and nowhere else.
  """

  import Plug.Conn

  import Phoenix.Controller,
    only: [redirect: 2, json: 2]

  require Logger

  @probe_cookie "_cyfr_pending_probe"

  @type outcome ::
          {:proceed, map()}
          | {:needs_legal, String.t() | nil}
          | {:needs_claim, String.t() | nil}
          | {:reauthenticate, atom()}
          | {:unavailable, atom()}

  @spec respond(Plug.Conn.t(), outcome(), keyword()) :: Plug.Conn.t()
  def respond(conn, outcome, opts)

  def respond(conn, {:proceed, report}, opts) do
    established(conn, opts, fn conn ->
      # A successful sign-in retires any stashed probe token — it was for
      # the claim or the re-probe that just concluded.
      conn
      |> delete_resp_cookie(@probe_cookie)
      |> flash_report(report)
      |> EmissaryWeb.SafeRedirect.post_login()
    end)
  end

  def respond(conn, {:needs_legal, _required_version}, opts) do
    established(conn, opts, fn conn ->
      conn
      |> maybe_stash_probe(opts)
      |> redirect(to: "/legal/accept")
    end)
  end

  def respond(conn, {:needs_claim, suggested}, opts) do
    established(conn, opts, fn conn ->
      conn
      |> maybe_stash_probe(opts)
      |> put_session(:claim_suggested_username, suggested || "")
      |> redirect(to: "/claim-namespace")
    end)
  end

  def respond(conn, {:reauthenticate, reason}, opts) do
    conn =
      case Keyword.get(opts, :teardown, :drop) do
        {:destroy_and_drop, token} ->
          _ = Sanctum.Session.destroy(token)

          conn
          |> delete_resp_cookie(@probe_cookie)
          |> safe_drop_session()

        :drop ->
          safe_drop_session(conn)
      end

    conn =
      if Keyword.get(opts, :reauth_flash, false),
        do: put_flash_if_available(conn, :error, reauth_flash_message(reason)),
        else: conn

    redirect(conn, to: "/login")
  end

  def respond(conn, {:unavailable, reason}, opts) do
    # Nothing was set up. A mint-path failure leaves no session behind; an
    # existing session (post-legal) stands so the person can retry from it.
    conn =
      case Keyword.fetch!(opts, :session) do
        {:mint, _ctx} -> safe_drop_session(conn)
        _ -> conn
      end

    conn
    |> put_status(:service_unavailable)
    |> put_resp_content_type("text/html")
    |> send_resp(503, unavailable_page(reason, Keyword.get(opts, :retry_path, "/login")))
  end

  @doc """
  The registry-outage copy, per reason: `{title, message}`. The browser
  owner of these sentences — the CLI's versions live beside the wire
  adapter in `Sanctum.Auth.DeviceFlow`.
  """
  @spec unavailable_copy(atom()) :: {String.t(), String.t()}
  def unavailable_copy(:no_access_token) do
    {"Sign-in incomplete",
     "Your identity provider returned no access token, so cyfr.run could not be asked " <>
       "for your namespace. Nothing was set up. Sign in again."}
  end

  def unavailable_copy(:namespace_conflict) do
    {"Namespace already in use here",
     "cyfr.run names you by a namespace another identity on this server already holds. " <>
       "Ask the operator to sort it out."}
  end

  def unavailable_copy(_registry_unreachable) do
    {"cyfr.run could not be reached",
     "Your namespace on cyfr.run is your identity on every server, and this server " <>
       "could not reach it to find or claim yours. Nothing was set up. Try again in a moment."}
  end

  @doc """
  Put a flash message only if flash is available on the conn — some test
  paths exercise these responses without the full browser plug stack.
  """
  def put_flash_if_available(conn, kind, msg) do
    Phoenix.Controller.put_flash(conn, kind, msg)
  rescue
    _ -> conn
  end

  @doc "Drop the Plug session; a no-op when none was fetched (API routes)."
  def safe_drop_session(conn) do
    configure_session(conn, drop: true)
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
            fun.(put_session(conn, :sanctum_session_token, session.token))

          {:error, reason} ->
            Logger.error("[EmissaryWeb.SignInResponse] session create failed: #{inspect(reason)}")

            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "session_error", message: "Unable to process request"})
        end

      {:token, token} ->
        fun.(put_session(conn, :sanctum_session_token, token))

      :existing ->
        fun.(conn)
    end
  end

  defp maybe_stash_probe(conn, opts) do
    case Keyword.get(opts, :access_token) do
      token when is_binary(token) and token != "" -> stash_pending_probe(conn, token)
      _ -> conn
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
          "[EmissaryWeb.SignInResponse] failed to stash pending_probe cookie: #{Exception.message(e)}"
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

  defp flash_report(conn, _report), do: conn

  defp reauth_flash_message(:idp_expired) do
    "Your login session expired during credential setup. Please sign in again."
  end

  # A first-time person whom the registry could not place: nothing was set
  # up and there is no session — a plain page and a way to try again.
  defp unavailable_page(reason, retry_path) do
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
end
