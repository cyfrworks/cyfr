# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.BrowserCSPTest do
  @moduledoc """
  The Prism pages' content security policy: same-origin connections on
  every page, `/pair` among them, which holds no key and fetches nothing
  from another home, and framed by nothing.
  """

  use CyfrWeb.ConnCase, async: true

  alias CyfrWeb.Plugs.BrowserCSP

  defp directives(conn) do
    [policy] = get_resp_header(conn, "content-security-policy")
    policy |> String.split("; ") |> Enum.sort()
  end

  test "the policy connects to this origin alone and is framed by nothing" do
    conn = BrowserCSP.call(Plug.Test.conn(:get, "/"), BrowserCSP.init([]))

    assert "connect-src 'self'" in directives(conn)
    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert "frame-ancestors 'none'" in directives(conn)
  end

  test "every page is served it" do
    for path <- ["/login", "/restore"] do
      policy = directives(get(build_conn(), path))
      assert "connect-src 'self'" in policy, path
      refute Enum.any?(policy, &(&1 =~ "https:")), path
    end
  end
end
