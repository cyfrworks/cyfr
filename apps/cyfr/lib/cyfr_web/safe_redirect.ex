# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.SafeRedirect do
  @moduledoc """
  Single source of truth for where a browser flow lands.

  Completed console sign-in flows land on the fixed console root. A door
  linked from the console returns to the athanor settings page it was
  started from, and to nothing else: `link_return/1` admits only that
  page's own path shape, so a destination taken from the request names
  one of this console's pages or falls back to the root, never another
  origin or path.
  """

  import Phoenix.Controller, only: [redirect: 2]

  @link_return ~r"\A/a/[A-Za-z0-9@._~-]{1,128}/settings\z"

  @doc "Issue the post-login redirect on `conn`."
  @spec post_login(Plug.Conn.t()) :: Plug.Conn.t()
  def post_login(conn), do: redirect(conn, to: "/")

  @doc """
  Where a door link returns: `path` when it is an athanor's settings page
  of this console (`/a/<athanor>/settings`), else the console root.
  """
  @spec link_return(term()) :: String.t()
  def link_return(path) when is_binary(path) do
    if Regex.match?(@link_return, path), do: path, else: "/"
  end

  def link_return(_path), do: "/"
end
