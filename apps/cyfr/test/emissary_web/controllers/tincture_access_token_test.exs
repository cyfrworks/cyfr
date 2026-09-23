# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.TinctureAccessTokenTest do
  @moduledoc """
  Tests exchanging a header credential for a short-lived tincture `?_t=` token.
  """
  use EmissaryWeb.ConnCase, async: false

  require Ecto.Query

  test "GET /t/access-token without credentials → 401", %{conn: conn} do
    conn = get(conn, "/t/access-token")
    assert json_response(conn, 401)["code"] == "unauthenticated"
  end

  test "GET /t/access-token with a valid Bearer key → 200 + a usable ?_t= token",
       %{conn: conn} do
    {:ok, %{api_key: key}} =
      Sanctum.ApiKey.create(Sanctum.TestContext.issuer!(Sanctum.TestContext.local()), %{
        name: "mint-key"
      })

    resp =
      conn
      |> put_req_header("authorization", "Bearer #{key}")
      |> get("/t/access-token?publisher=acme&tincture_name=dash")

    body = json_response(resp, 200)
    assert is_binary(body["token"])
    # The signed deadline's remainder: a key has no expiry of its own, so the
    # hour bounds it, less the instant the mint took.
    assert body["expires_in"] in 3590..3600

    # The minted token authenticates a fresh request for the tincture it names.
    token_conn = %Plug.Conn{
      query_string: "_t=#{body["token"]}",
      remote_ip: {127, 0, 0, 1},
      path_params: %{"publisher" => "acme", "tincture_name" => "dash"}
    }

    assert {:ok, %Sanctum.Context{auth_method: :tincture}} =
             Sanctum.TinctureAuth.authenticate(token_conn)

    # ...and no other.
    assert {:error, :wrong_tincture} =
             Sanctum.TinctureAuth.authenticate(%{
               token_conn
               | path_params: %{"publisher" => "acme", "tincture_name" => "billing"}
             })
  end

  test "expires_in is the signed remainder: a session ending sooner than the hour ends it",
       %{conn: conn} do
    ctx = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
    {:ok, session} = Sanctum.TestContext.create_session(ctx)
    soon = DateTime.add(DateTime.utc_now(), 600, :second)

    {1, _} =
      Arca.Repo.update_all(
        Ecto.Query.from(s in Arca.Schemas.Session,
          where: s.token_hash == ^Sanctum.Session.token_hash(session.token)
        ),
        set: [expires_at: soon]
      )

    body =
      conn
      |> put_req_header("authorization", "Bearer #{session.token}")
      |> get("/t/access-token?publisher=acme&tincture_name=dash")
      |> json_response(200)

    assert body["expires_in"] <= 600
    assert body["expires_in"] > 590
  end

  test "the mint names one tincture or refuses", %{conn: conn} do
    {:ok, %{api_key: key}} =
      Sanctum.ApiKey.create(Sanctum.TestContext.issuer!(Sanctum.TestContext.local()), %{
        name: "unscoped-key"
      })

    resp =
      conn
      |> put_req_header("authorization", "Bearer #{key}")
      |> get("/t/access-token")

    assert json_response(resp, 400)["code"] == "tincture_required"
  end

  test "a ?_t= token cannot mint its own successor", %{conn: conn} do
    # Self-renewal turns a leaked one-hour token into a permanent
    # credential: mint must demand the primary credential, so token expiry
    # actually means re-authentication.
    {:ok, %{api_key: key}} =
      Sanctum.ApiKey.create(Sanctum.TestContext.issuer!(Sanctum.TestContext.local()), %{
        name: "renew-key"
      })

    minted =
      conn
      |> put_req_header("authorization", "Bearer #{key}")
      |> get("/t/access-token?publisher=acme&tincture_name=dash")
      |> json_response(200)

    renew =
      get(
        build_conn(),
        "/t/access-token?publisher=acme&tincture_name=dash&_t=#{minted["token"]}"
      )

    assert json_response(renew, 403)["code"] == "token_cannot_renew_itself"
  end
end
