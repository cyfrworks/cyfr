# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.SignInResponse do
  @moduledoc """
  One transcription of an admitted sign-in to a browser response: the
  session an already-minted token names becomes the browser's cookie on a
  clean Plug session, and the browser lands on the console. Two tickets
  hand it a token: a sign-in's (`PrismWeb.PasskeyController`) and a
  protected device's unlock (`PrismWeb.DeviceUnlockController`).

  The session token travels in the cookie and nowhere else.
  """

  import Plug.Conn

  @session_key CyfrWeb.ContextGuard.session_key()

  @doc """
  The Plug session key holding the Sanctum session token. This module is
  the one writer; the spelling is the guard's that reads it on every
  protected mount (`CyfrWeb.ContextGuard.session_key/0`), and every other
  reader takes it from here (LiveView mounts see the session as a
  string-keyed map — `to_string/1` it).
  """
  def session_key, do: @session_key

  @doc "Cookie the session `token` names on a clean Plug session and land (the module doc)."
  @spec respond(Plug.Conn.t(), :proceed, session: {:token, String.t()}) :: Plug.Conn.t()
  def respond(conn, :proceed, session: {:token, token}) when is_binary(token) do
    conn
    |> renew_session()
    |> put_session(@session_key, token)
    |> CyfrWeb.SafeRedirect.post_login()
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

  # Start the authenticated session on a clean one. Whatever the browser
  # carried while anonymous — most of all Phoenix's `_csrf_token`, which is
  # the value `PasskeyController.same_browser?/2` binds a sign-in ticket to
  # — must not survive the exchange, or a session an attacker could plant on
  # this origin beforehand keeps its hold afterwards. `clear_session/1` drops
  # the data (the cookie store keeps no id to rotate) and `renew: true` moves
  # the id for a server-side store.
  defp renew_session(conn), do: conn |> configure_session(renew: true) |> clear_session()
end
