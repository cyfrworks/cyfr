# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AuthController do
  @moduledoc """
  Browser sign-out. A person signs in with their account at the sign-in
  page (`PrismWeb.LoginLive`), which sets the session through a one-time
  ticket (`PrismWeb.PasskeyController`).

  ## Routes

  - `POST /auth/logout` - Browser sign-out (cookie session, forgery-guarded)

  An API caller's sign-out and session read, by bearer token, are the
  HTTP API's, not the browser's.
  """

  use PrismWeb, :controller

  alias CyfrWeb.Plugs.CallIdentity
  alias CyfrWeb.SignInResponse
  alias Sanctum.Session

  @not_signed_out "The server could not sign you out just now, so you are still signed in. Try again."

  @doc """
  The browser's sign-out (`POST /auth/logout`): retires the Sanctum
  session the cookie names, drops the cookie session, and lands on the
  sign-in page.

  POST, never GET, so signing someone out is not one `<img src>` away:
  the route's browser pipeline checks the forgery token first.

  The redirect follows the store's answer that it removed the session
  the cookie names or that there was none to remove
  (`Sanctum.Session.destroy/1`), or a cookie that names no session at
  all. Another member may go on honouring a removed session's cached
  authorization until the invalidation reaches it or the cache entry
  expires, the bound `Sanctum.Caller.invalidate_hash/1` documents. When
  the store cannot answer, the answer is `503` with no redirect, and the
  cookie session is kept: the session may still stand and the same
  sign-out can be sent again.
  """
  def browser_logout(conn, _params) do
    case get_session(conn, SignInResponse.session_key()) do
      token when is_binary(token) and token != "" ->
        case Session.destroy(token) do
          {:ok, _removed_or_absent} ->
            signed_out(conn)

          {:error, _reason} ->
            conn
            |> CallIdentity.refused(503, @not_signed_out)
            |> put_resp_content_type("text/plain")
            |> send_resp(503, @not_signed_out)
        end

      _none ->
        signed_out(conn)
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp signed_out(conn) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/login?error=signed_out")
  end
end
