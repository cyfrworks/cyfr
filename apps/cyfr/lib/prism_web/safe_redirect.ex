# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SafeRedirect do
  @moduledoc """
  Single source of truth for the post-login landing redirect.

  Redirects completed console sign-in flows to the fixed console root.
  The destination is never taken from user input.
  """

  import Phoenix.Controller, only: [redirect: 2]

  @doc "Issue the post-login redirect on `conn`."
  @spec post_login(Plug.Conn.t()) :: Plug.Conn.t()
  def post_login(conn), do: redirect(conn, to: "/")
end
