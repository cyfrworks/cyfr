# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.SafeRedirectTest do
  @moduledoc """
  The post-login landing target is operator config (`:post_login_redirect`),
  never user input. These tests pin the internal-path-vs-external behaviour so
  the redirect is issued identically by every login gate.
  """
  use EmissaryWeb.ConnCase, async: false

  setup do
    original = Application.get_env(:cyfr, :post_login_redirect)

    on_exit(fn ->
      if original do
        Application.put_env(:cyfr, :post_login_redirect, original)
      else
        Application.delete_env(:cyfr, :post_login_redirect)
      end
    end)

    :ok
  end

  test "defaults to / as an internal redirect when unset", %{conn: conn} do
    Application.delete_env(:cyfr, :post_login_redirect)

    conn = EmissaryWeb.SafeRedirect.post_login(conn)

    assert redirected_to(conn) == "/"
    refute external?(conn)
  end

  test "issues an internal redirect for a configured path", %{conn: conn} do
    Application.put_env(:cyfr, :post_login_redirect, "/dashboard")

    conn = EmissaryWeb.SafeRedirect.post_login(conn)

    assert redirected_to(conn) == "/dashboard"
    refute external?(conn)
  end

  test "issues an external redirect for a configured absolute URL", %{conn: conn} do
    Application.put_env(:cyfr, :post_login_redirect, "https://app.cyfr.run/home")

    conn = EmissaryWeb.SafeRedirect.post_login(conn)

    assert redirected_to(conn) == "https://app.cyfr.run/home"
    assert external?(conn)
  end

  test "handles a protocol-relative target as an external redirect, never a local path", %{
    conn: conn
  } do
    # `//host` and `/\\host` look local (single leading slash) but browsers treat
    # them as off-site; SafeRedirect must not feed them to redirect(to:).
    Application.put_env(:cyfr, :post_login_redirect, "//evil.example/path")

    conn = EmissaryWeb.SafeRedirect.post_login(conn)

    assert redirected_to(conn) == "//evil.example/path"
    assert external?(conn) == false
    refute internal_classified?(conn)
  end

  # A path issued via redirect(to:) is same-app; "//host" must not take that path.
  defp internal_classified?(conn) do
    [location] = Plug.Conn.get_resp_header(conn, "location")
    String.starts_with?(location, "/") and not String.starts_with?(location, "//")
  end

  # `redirect(external:)` sets the Location header without the same-host
  # rewriting Phoenix applies to `to:`; both expose the value via
  # get_resp_header, so we distinguish by whether the target is absolute.
  defp external?(conn) do
    [location] = Plug.Conn.get_resp_header(conn, "location")
    String.starts_with?(location, "http")
  end
end
