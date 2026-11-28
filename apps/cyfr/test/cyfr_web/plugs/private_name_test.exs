# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.PrivateNameTest do
  @moduledoc """
  A page asked for at the loopback listener under another host than the
  private name is sent to the same path and query at the private address
  (`CyfrWeb.Plugs.PrivateName`), through the endpoint and the router as a
  browser's request reaches it; at the private name, at the proxy
  listener, and on a route a program calls, it is served as it came. The
  OAuth return under `localhost` completes there
  (`Emissary.Web.OAuthCallbackControllerTest`).
  """

  use CyfrWeb.ConnCase, async: false

  defp at(host, entry \\ :loopback) do
    Sanctum.ClientIp.put_ingress(%{build_conn() | host: host}, entry)
  end

  test "a page at localhost or 127.0.0.1 is sent to the same path and query at the private address" do
    private = Sanctum.private_address()

    assert redirected_to(get(at("localhost"), "/"), 302) == private <> "/"

    assert redirected_to(get(at("127.0.0.1"), "/login?error=signed_out"), 302) ==
             private <> "/login?error=signed_out"

    # Whatever the request names as its host, the destination is the
    # configured one.
    assert redirected_to(get(at("evil.example"), "/login"), 302) == private <> "/login"
  end

  test "a page at the private name is served" do
    host = URI.parse(Sanctum.private_address()).host

    assert get(at(host), "/login").status == 200
    assert get(at(String.upcase(host)), "/login").status == 200
  end

  test "a route a program calls is served under localhost as before" do
    health = get(at("localhost"), "/api/health")

    assert health.status == 200
    assert get_resp_header(health, "location") == []
  end

  test "the proxy listener never sends a page anywhere" do
    Prima.Test.Env.put_app_env(:sanctum, :browser_address, "https://cyfr.example")

    for host <- ["cyfr.example", "localhost"] do
      assert get(at(host, :proxy), "/login").status == 200, host
    end
  end
end
