# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.SafeRedirect do
  @moduledoc """
  Single source of truth for where a browser flow lands.

  Completed console sign-in flows land on the fixed console root.
  """

  import Phoenix.Controller, only: [redirect: 2]

  @doc "Issue the post-login redirect on `conn`."
  @spec post_login(Plug.Conn.t()) :: Plug.Conn.t()
  def post_login(conn), do: redirect(conn, to: "/")
end
