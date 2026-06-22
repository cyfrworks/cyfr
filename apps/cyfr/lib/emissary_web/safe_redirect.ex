# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.SafeRedirect do
  @moduledoc """
  Single source of truth for the post-login landing redirect.

  The landing target is operator configuration (`:post_login_redirect`,
  default `"/"`), never user input. This helper exists so every gate that
  finishes the login flow resolves and issues that redirect identically:
  an internal path (`/...`) is issued as a same-app redirect, anything else
  (e.g. a split-frontend absolute URL) as an external redirect.
  """

  import Phoenix.Controller, only: [redirect: 2]

  @doc """
  Resolve `:post_login_redirect` and issue the redirect on `conn`.

  Internal paths use `redirect(to:)`; absolute URLs use `redirect(external:)`.
  """
  @spec post_login(Plug.Conn.t()) :: Plug.Conn.t()
  def post_login(conn) do
    target = Application.get_env(:cyfr, :post_login_redirect, "/")

    if internal_path?(target) do
      redirect(conn, to: target)
    else
      redirect(conn, external: target)
    end
  end

  # A genuinely-local path: a single leading "/" that is not a protocol-relative
  # ("//host") or backslash-smuggled ("/\\host") URL — both of which browsers
  # treat as off-site. Keeps `redirect(to:)` fed only with same-app paths;
  # anything else (including intentional split-frontend absolute URLs) goes out
  # as an explicit external redirect.
  defp internal_path?(target) do
    String.starts_with?(target, "/") and
      not String.starts_with?(target, "//") and
      not String.starts_with?(target, "/\\")
  end
end
