defmodule PrismWeb.AuthController do
  @moduledoc """
  Authentication controller for Prism.

  Handles session establishment after Device Flow completes
  and logout. No OAuth callbacks needed.
  """

  use PrismWeb, :controller

  alias Sanctum.Session

  @doc """
  Store session token in cookie after Device Flow completes.

  The LiveView polls Device Flow, gets a session token, and
  redirects here to persist it in the cookie session.
  """
  def session(conn, %{"code" => code}) do
    with {:ok, token} <- Prism.AuthExchange.redeem(code),
         {:ok, _user} <- Session.get_user(token) do
      Prism.SessionBridge.save_token(token)

      conn
      |> configure_session(renew: true)
      |> put_session(:session_token, token)
      |> redirect(to: ~p"/")
    else
      _ ->
        conn
        |> put_flash(:error, "Invalid or expired login code. Please sign in again.")
        |> redirect(to: ~p"/login")
    end
  end

  def session(conn, _params) do
    conn
    |> redirect(to: ~p"/login")
  end

  def logout(conn, _params) do
    token = get_session(conn, :session_token)

    if token do
      Session.destroy(token)
    end

    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/login")
  end
end
