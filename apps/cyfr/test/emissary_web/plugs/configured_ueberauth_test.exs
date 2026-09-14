# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.ConfiguredUeberauthTest.Strategy do
  @moduledoc false
  # A strategy that only redirects, so the route table can be exercised
  # without an issuer to discover.
  use Ueberauth.Strategy

  def handle_request!(conn), do: redirect!(conn, "https://idp.test/authorize")
end

defmodule EmissaryWeb.Plugs.ConfiguredUeberauthTest do
  @moduledoc """
  The route table is built from `:ueberauth, Ueberauth`, which
  `config/runtime.exs` fills in at boot while `config/config.exs` has
  `providers: []`. Only a request through the router can tell a table baked
  at compile time from one read per call.
  """
  use EmissaryWeb.ConnCase, async: false

  setup do
    original = Application.get_env(:ueberauth, Ueberauth)

    on_exit(fn ->
      if original,
        do: Application.put_env(:ueberauth, Ueberauth, original),
        else: Application.delete_env(:ueberauth, Ueberauth)
    end)

    :ok
  end

  test "a provider configured after compile is reachable through the router", %{conn: conn} do
    Application.put_env(:ueberauth, Ueberauth,
      providers: [oidcc: {EmissaryWeb.Plugs.ConfiguredUeberauthTest.Strategy, []}]
    )

    conn = get(conn, "/auth/oidcc")

    assert conn.status == 302
    assert Plug.Conn.get_resp_header(conn, "location") == ["https://idp.test/authorize"]
  end

  test "a provider this boot did not configure answers the 404", %{conn: conn} do
    Application.put_env(:ueberauth, Ueberauth, providers: [])

    assert html_response(get(conn, "/auth/github"), 404) =~ "Unknown sign-in provider"
  end
end
