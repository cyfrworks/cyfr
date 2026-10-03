# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.SessionController do
  @moduledoc """
  The HTTP API's sign-out and session read, for API callers holding a
  session token.

  ## Routes

  - `DELETE /auth/logout` - Destroys session (API callers, bearer token)
  - `GET /auth/whoami` - Returns the session's info

  Each accepts the credential only from the `Authorization: Bearer`
  header. The browser signs out through its own route, `POST /auth/logout`,
  which reads only the cookie session.
  """

  use Emissary.Web, :controller

  alias CyfrWeb.SignInResponse
  alias Sanctum.Session

  @doc """
  Logout - destroys the session, for API callers (`DELETE /auth/logout`).

  Accepts the credential only from the `Authorization: Bearer` header.
  """
  def logout(conn, _params) do
    token = get_bearer_token(conn)

    if token && token != "" do
      case Session.destroy(token) do
        :ok ->
          conn
          |> SignInResponse.safe_drop_session()
          |> json(%{ok: true, message: "Logged out successfully"})

        {:error, reason} ->
          CyfrWeb.ApiError.refuse(conn, reason)
      end
    else
      CyfrWeb.ApiError.refuse(conn, :missing_token)
    end
  end

  @doc """
  Returns current session info.

  Requires Authorization: Bearer {token} header.
  """
  def whoami(conn, _params) do
    case get_bearer_token(conn) do
      nil ->
        CyfrWeb.ApiError.refuse(conn, :missing_token)

      token ->
        case Session.get(token) do
          {:ok, session} ->
            conn
            |> json(%{
              ok: true,
              session: %{
                user_id: session.user_id,
                email: session.email,
                provider: session.provider,
                created_at: session.created_at,
                expires_at: session.expires_at
              }
            })

          {:error, _} ->
            CyfrWeb.ApiError.send(conn, 401, :invalid_session, nil)
        end
    end
  end

  defp get_bearer_token(conn), do: Sanctum.BearerToken.read(conn)
end
