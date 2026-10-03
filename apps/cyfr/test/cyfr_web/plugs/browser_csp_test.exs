# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.BrowserCSPTest do
  @moduledoc """
  The Prism pages' content security policy: same-origin connections on
  every page, and on the glass's page alone (`/pair`) connections to any
  HTTPS origin, since a device certified by its person's own home renews
  its certificate there by `fetch`. Every other directive is the same on
  both.
  """

  use CyfrWeb.ConnCase, async: true

  alias CyfrWeb.Plugs.BrowserCSP

  defp directives(conn) do
    [policy] = get_resp_header(conn, "content-security-policy")
    policy |> String.split("; ") |> Enum.sort()
  end

  test "the default policy connects to this origin alone; the glass's adds any HTTPS origin" do
    plain = BrowserCSP.call(Plug.Test.conn(:get, "/"), BrowserCSP.init([]))
    glass = BrowserCSP.call(Plug.Test.conn(:get, "/pair"), BrowserCSP.init(connect: :https))

    assert "connect-src 'self'" in directives(plain)
    assert "connect-src 'self' https:" in directives(glass)

    assert directives(plain) -- ["connect-src 'self'"] ==
             directives(glass) -- ["connect-src 'self' https:"]

    for conn <- [plain, glass] do
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
      assert "frame-ancestors 'none'" in directives(conn)
    end

    assert_raise ArgumentError, fn -> BrowserCSP.init(connect: :anything) end
  end

  test "only /pair is served the wider policy", %{conn: conn} do
    assert "connect-src 'self' https:" in directives(get(conn, "/pair"))

    for path <- ["/login", "/restore"] do
      policy = directives(get(build_conn(), path))
      assert "connect-src 'self'" in policy, path
      refute Enum.any?(policy, &(&1 =~ "https:")), path
    end
  end
end
