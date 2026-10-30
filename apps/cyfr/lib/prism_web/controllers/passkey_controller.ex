# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.PasskeyController do
  @moduledoc """
  Passkey sign-in's last hop: the sign-in page (`PrismWeb.LoginLive`)
  held the challenge, verified the passkey's answer and minted the session
  (`Sanctum.Passkeys.sign_in/2`), and hands a one-time ticket to
  `GET /auth/passkey/complete/:ticket`, which sets the cookie session and
  routes as every sign-in does (`CyfrWeb.SignInResponse`). The pages that
  admit a new person (`PrismWeb.AdmissionCard`, on the setup, invitation
  and sign-in pages) hand the same ticket once the person says their
  recovery code is saved, marked `notice: :recovery_code_saved`, and the
  landing page shows the flash that offers another code. No request
  chooses where a ticket lands or what it says.

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
      {:ok, %{session_token: token} = payload} when is_binary(token) ->
        if same_browser?(conn, payload) do
          conn
          |> notice(payload[:notice])
          |> SignInResponse.respond(:proceed, session: {:token, token})
        else
          Logger.warning(
            "[PasskeyController] passkey ticket presented by a different browser than the " <>
              "one that signed in — refusing"
          )

          refused(
            conn,
            403,
            "That sign-in was started in a different browser. Please sign in again."
          )
        end

      _missing ->
        refused(conn, 404, "That sign-in expired. Please try again.")
    end
  end

  def complete(conn, _params), do: refused(conn, 404, "That sign-in expired. Please try again.")

  # The flash a ticket's landing shows, put before the sign-in's response,
  # which redirects.
  defp notice(conn, :recovery_code_saved) do
    SignInResponse.put_flash_if_available(
      conn,
      :info,
      "Saved. You can add another recovery code in Settings, and keep it apart from this one."
    )
  end

  defp notice(conn, _none), do: conn

  defp same_browser?(conn, %{browser_binding: binding}) when is_binary(binding) do
    case get_session(conn, "_csrf_token") do
      current when is_binary(current) and current != "" ->
        Plug.Crypto.secure_compare(current, binding)

      _ ->
        false
    end
  end

  defp same_browser?(_conn, _payload), do: false

  # A sign-in refused here is the request's refused decision, recorded
  # once under its sentence with no person or athanor
  # (`CyfrWeb.Plugs.CallIdentity.refused/3`), and the browser goes back to
  # the sign-in page.
  defp refused(conn, status, message) do
    conn
    |> CyfrWeb.Plugs.CallIdentity.refused(status, message)
    |> SignInResponse.put_flash_if_available(:error, message)
    |> redirect(to: "/login")
  end
end
