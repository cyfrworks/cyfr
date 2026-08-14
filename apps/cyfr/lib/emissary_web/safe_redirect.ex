# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.SafeRedirect do
  @moduledoc """
  Single source of truth for the post-login landing redirect.

  The landing target is the console root — never user input — and every
  gate that finishes the login flow issues it through this helper so the
  flows can't drift.
  """

  import Phoenix.Controller, only: [redirect: 2]

  @doc "Issue the post-login redirect on `conn`."
  @spec post_login(Plug.Conn.t()) :: Plug.Conn.t()
  def post_login(conn), do: redirect(conn, to: "/")
end
