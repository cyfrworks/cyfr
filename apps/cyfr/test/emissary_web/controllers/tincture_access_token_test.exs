# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.TinctureAccessTokenTest do
  @moduledoc """
  Phase 2 S7: the cross-origin token-mint endpoint. A client exchanges its
  Bearer/session credential (sent as a header, never a URL) for a short-lived
  ?_t= token.
  """
  use EmissaryWeb.ConnCase, async: false

  test "GET /t/access-token without credentials → 401", %{conn: conn} do
    conn = get(conn, "/t/access-token")
    assert json_response(conn, 401)["code"] == "unauthenticated"
  end

  test "GET /t/access-token with a valid Bearer key → 200 + a usable ?_t= token",
       %{conn: conn} do
    {:ok, %{api_key: key}} =
      Sanctum.ApiKey.create(Sanctum.TestContext.local(), %{name: "mint-key"})

    resp =
      conn
      |> put_req_header("authorization", "Bearer #{key}")
      |> get("/t/access-token")

    body = json_response(resp, 200)
    assert is_binary(body["token"])
    assert body["expires_in"] == 3600

    # The minted token authenticates a fresh tincture request.
    token_conn = %Plug.Conn{query_string: "_t=#{body["token"]}", remote_ip: {127, 0, 0, 1}}

    assert {:ok, %Sanctum.Context{auth_method: :tincture}} =
             Sanctum.TinctureAuth.authenticate(token_conn)
  end

  test "a ?_t= token cannot mint its own successor", %{conn: conn} do
    # Self-renewal turns a leaked one-hour token into a permanent
    # credential: mint must demand the primary credential, so token expiry
    # actually means re-authentication.
    {:ok, %{api_key: key}} =
      Sanctum.ApiKey.create(Sanctum.TestContext.local(), %{name: "renew-key"})

    minted =
      conn
      |> put_req_header("authorization", "Bearer #{key}")
      |> get("/t/access-token")
      |> json_response(200)

    renew = get(build_conn(), "/t/access-token?_t=#{minted["token"]}")
    assert json_response(renew, 403)["code"] == "token_cannot_renew_itself"
  end
end
