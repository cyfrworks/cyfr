# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.ConfiguredUeberauthTest do
  @moduledoc """
  Two things this plug has to get right, and both were once wrong.

  **Drop unready strategies.** GitHub device-flow apps ship a client id and
  no secret. If that still registers Ueberauth's GitHub strategy, `GET
  /auth/github` raises ArgumentError inside
  `Ueberauth.Strategy.Github.OAuth.client/1`, so the request 500s.

  **See the providers the boot actually configured.** The route table is
  built from `:ueberauth, Ueberauth`, which `config/runtime.exs` fills in at
  boot; `config/config.exs` has `providers: []`. Building it in `init/1` —
  which Phoenix runs at *compile* time everywhere but dev — baked the empty
  table into every release, and web sign-in answered the not-configured 404
  for a fully configured server. The route-level test below is the one that
  can tell those two states apart; calling `init/1` and `call/2` by hand
  cannot, because the hand-call inits after the env is set.
  """
  use EmissaryWeb.ConnCase, async: false

  alias EmissaryWeb.Plugs.ConfiguredUeberauth

  setup do
    original_providers = Application.get_env(:ueberauth, Ueberauth)
    original_github = Application.get_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)

    on_exit(fn ->
      if original_providers,
        do: Application.put_env(:ueberauth, Ueberauth, original_providers),
        else: Application.delete_env(:ueberauth, Ueberauth)

      if original_github,
        do: Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth, original_github),
        else: Application.delete_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)
    end)

    :ok
  end

  defp configure_provider! do
    Application.put_env(:ueberauth, Ueberauth,
      providers: [{:github, {Ueberauth.Strategy.Github, [default_scope: "user:email"]}}]
    )
  end

  test "GET /auth/github with a GitHub strategy and no OAuth secret does not raise" do
    configure_provider!()
    Application.delete_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)

    conn = Plug.Test.conn(:get, "/auth/github")
    conn = ConfiguredUeberauth.call(conn, ConfiguredUeberauth.init([]))

    refute conn.halted
    refute conn.status == 500
  end

  test "a provider configured after compile is reachable through the router", %{conn: conn} do
    # The regression: `providers:` is empty at compile time and filled in by
    # config/runtime.exs at boot, so a plug that resolved its routes in
    # `init/1` served the "provider is not configured" 404 to a server that
    # had configured it. Asserting the redirect — not merely "not 500" —
    # is what distinguishes a live strategy from a dropped one.
    configure_provider!()

    Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth,
      client_id: "test-client-id",
      client_secret: "test-client-secret"
    )

    conn = get(conn, "/auth/github")

    assert conn.status == 302
    assert [location] = Plug.Conn.get_resp_header(conn, "location")
    assert location =~ "https://github.com/login/oauth/authorize"
    assert location =~ "client_id=test-client-id"
  end

  test "an unready provider still falls through to the 404, not a crash", %{conn: conn} do
    configure_provider!()
    Application.delete_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)

    conn = get(conn, "/auth/github")

    assert conn.status == 404
  end
end
