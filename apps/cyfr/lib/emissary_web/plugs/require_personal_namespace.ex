# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.RequirePersonalNamespace do
  @moduledoc """
  Gates browser routes behind a claimed personal namespace.

  Logic:

  1. Bypass `/claim-namespace/*`, `/legal/*`, `/login`, `/auth/*`,
     `/api/health`, `/mcp/*`, `/assets/*`, `/t/*` (tincture routes use
     query-param auth, not the session).
  2. Load the session from the cookie; no session, or one this server no
     longer recognises, lets the request through — route-level auth plugs
     or controller guards handle un-authed access.
  3. A session that loads `authenticated: true` passes: the person's
     namespace is recorded on their `users` row (`Sanctum.Namespace`).
  4. A session that loads `authenticated: false` with no namespace is a
     person ahead of the claim — halt and redirect to `/claim-namespace`.
     One with a namespace but still unauthenticated has been denied at the
     door since it was minted — drop it and send them to `/login`.
  5. A transient failure reading who the person is answers 503, never a
     redirect into a claim they have already made.

  This plug answers HTTP GETs. The LiveView socket is handled by the
  endpoint before the router and never passes through here, so the
  connected mount is gated again in `PrismWeb.LiveAuth`.

  `/legal` and `/login` are bypassed: a person ahead of the claim gate must
  reach the policy-acceptance page (cyfr.run asks for it before the claim)
  and the sign-in page.
  """

  import Plug.Conn

  require Logger

  @bypass_prefixes ~w(/claim-namespace /legal /login /auth /api/health /mcp /assets /t)

  def init(opts), do: opts

  def call(conn, _opts) do
    if bypass?(conn.request_path) do
      conn
    else
      conn = fetch_session(conn)

      case get_session(conn, :sanctum_session_token) do
        token when is_binary(token) and token != "" -> gate(conn, token)
        _ -> conn
      end
    end
  end

  # Match on path-segment boundaries, not arbitrary string prefixes — so a
  # future route like `/claim-namespace-evil` doesn't silently inherit the
  # bypass that's intended only for `/claim-namespace` and its descendants.
  defp bypass?(path) do
    Enum.any?(@bypass_prefixes, fn prefix ->
      path == prefix or String.starts_with?(path, prefix <> "/")
    end)
  end

  defp gate(conn, token) do
    case Sanctum.Session.load(token, surface: :console) do
      {:ok, %{authenticated: true}} ->
        conn

      {:ok, %{authenticated: false, namespace: nil, user_id: user_id}} when is_binary(user_id) ->
        conn
        |> Phoenix.Controller.redirect(to: "/claim-namespace")
        |> halt()

      {:ok, %{authenticated: false, user_id: user_id}} when is_binary(user_id) ->
        conn
        |> configure_session(drop: true)
        |> Phoenix.Controller.redirect(to: "/login")
        |> halt()

      {:error, reason} when reason in [:namespace_unavailable, :database_error] ->
        Logger.warning(
          "[RequirePersonalNamespace] could not read who the session belongs to " <>
            "(#{inspect(reason)}) — answering 503, not the claim gate"
        )

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(503, "Try again shortly.")
        |> halt()

      _ ->
        conn
    end
  end
end
