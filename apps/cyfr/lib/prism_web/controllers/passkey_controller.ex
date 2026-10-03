# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.PasskeyController do
  @moduledoc """
  Passkey sign-in's last hop: the sign-in page (`PrismWeb.LoginLive`)
  held the challenge, verified the passkey's answer and minted the session
  (`Sanctum.Passkeys.sign_in/2`), and hands a one-time ticket to
  `GET /auth/passkey/complete/:ticket`, which sets the cookie session and
  routes as every sign-in does (`CyfrWeb.SignInResponse`).

  The ticket is taken in one operation, so of two requests presenting it
  only one finds it, and it is spent whichever way the check goes. It is
  bound to the browser that started the sign-in, through the session's
  forgery token, so a ticket handed to another browser signs no one in.
  """

  use PrismWeb, :controller

  require Logger

  alias CyfrWeb.SignInResponse

  @doc "Set the cookie session a passkey sign-in minted (the module doc)."
  def complete(conn, %{"ticket" => ticket})
      when is_binary(ticket) and byte_size(ticket) > 0 and byte_size(ticket) <= 64 do
    case Arca.Cache.take({:login_passkey_ticket, ticket}) do
      {:ok, %{session_token: token, outcome: outcome} = payload} when is_binary(token) ->
        if same_browser?(conn, payload) do
          SignInResponse.respond(conn, outcome, session: {:token, token})
        else
          Logger.warning(
            "[PasskeyController] passkey ticket presented by a different browser than the " <>
              "one that signed in — refusing"
          )

          expired(conn, "That sign-in was started in a different browser. Please sign in again.")
        end

      _missing ->
        expired(conn, "That sign-in expired. Please try again.")
    end
  end

  def complete(conn, _params), do: expired(conn, "That sign-in expired. Please try again.")

  defp same_browser?(conn, %{browser_binding: binding}) when is_binary(binding) do
    case get_session(conn, "_csrf_token") do
      current when is_binary(current) and current != "" ->
        Plug.Crypto.secure_compare(current, binding)

      _ ->
        false
    end
  end

  defp same_browser?(_conn, _payload), do: false

  defp expired(conn, message) do
    conn
    |> SignInResponse.put_flash_if_available(:error, message)
    |> redirect(to: "/login")
  end
end
