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

  A sign-out of a session the token establishes, its person's door since
  closed included, is the gate's `session logout` (`Sanctum.Gate`), so it
  leaves the decision row that operation leaves over `/mcp`. A token that
  establishes no caller holds no authority to take away: its row, if one
  is left, is removed and the answer is the same success.
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
      conn |> sign_out(token) |> logged_out(conn)
    else
      CyfrWeb.ApiError.refuse(conn, :missing_token)
    end
  end

  # The caller the token establishes signs out through the gate, as an API
  # call over `/mcp` would; a door-denied one too, since the operation is
  # anonymous and ends the session the context names. A session about to
  # end is not slid.
  defp sign_out(conn, token) do
    case Sanctum.Caller.establish({:session, token}, refresh: false) do
      {:ok, ctx} -> gate_logout(conn, ctx)
      {:error, {:denied, ctx}} -> gate_logout(conn, ctx)
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, _establishes_no_caller} -> Session.destroy(token)
    end
  end

  defp gate_logout(conn, ctx) do
    ctx = %{ctx | origin: :programmatic, client_ip: Sanctum.ClientIp.resolve(conn)}

    with {:ok, _answer} <- Sanctum.Gate.call_external("session", ctx, %{"action" => "logout"}),
         do: :ok
  end

  defp logged_out(:ok, conn) do
    conn
    |> SignInResponse.safe_drop_session()
    |> json(%{ok: true, message: "Logged out successfully"})
  end

  defp logged_out({:error, reason}, conn), do: CyfrWeb.ApiError.refuse(conn, reason)

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
