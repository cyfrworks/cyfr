# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SessionController do
  @moduledoc """
  Sign out from the browser: retire the Sanctum session the cookie names,
  drop the cookie session, and land on the sign-in page.
  """

  use PrismWeb, :controller

  alias Sanctum.Session

  def logout(conn, _params) do
    case get_session(conn, EmissaryWeb.SignInResponse.session_key()) do
      token when is_binary(token) and token != "" -> Session.destroy(token)
      _ -> :ok
    end

    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/login?error=signed_out")
  end
end
