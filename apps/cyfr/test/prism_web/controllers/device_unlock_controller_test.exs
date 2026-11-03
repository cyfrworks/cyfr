# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.DeviceUnlockControllerTest do
  @moduledoc """
  A protected device's unlock, its browser's last hop: the GET page
  creates nothing, keeps nothing and passes on no referrer; the POST
  spends the ticket once and sets the session's HttpOnly cookie, for a
  session the device's channel alone slides; a ticket spent, unknown or
  locked first answers a page and sets nothing. No browser binding: a
  ticket redeems in whichever browser posts it first.
  """

  use PrismWeb.ConnCase, async: false

  import Cyfr.Test.ProtectedDevice

  @token String.duplicate("3b", 32)

  setup do
    Arca.Cache.init()
    Prima.Test.RateLimiter.reset!()

    on_exit(fn ->
      Prima.Test.RateLimiter.reset!()
    end)

    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)
    Sanctum.Test.Newcomers.directory!()
    Arca.Repo.delete_all(Arca.Schemas.User)
    device = enrolled!(@token)
    %{device: device, ctx: connected!(device)}
  end

  defp cookie_session(conn) do
    conn.resp_cookies
    |> Map.values()
    |> Enum.find(&String.contains?(&1[:value] || "", "."))
  end

  test "the page posts the fragment's ticket and creates nothing", %{conn: conn} do
    before = Arca.Repo.aggregate(Arca.Schemas.Session, :count)
    conn = get(conn, "/auth/device/complete")

    assert html = html_response(conn, 200)
    assert html =~ ~s(data-device-unlock)
    assert html =~ ~s(name="ticket")
    assert html =~ ~s(name="_csrf_token")
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert Arca.Repo.aggregate(Arca.Schemas.Session, :count) == before
    assert get_session(conn, "sanctum_session_token") == nil
  end

  test "a ticket spent once sets the session's cookie, and a second time nothing", %{
    conn: conn,
    device: device,
    ctx: ctx
  } do
    answer = unlocked!(ctx, device.key)
    redeemed = post(conn, "/auth/device/complete", %{"ticket" => answer.ticket})

    assert redirected_to(redeemed, 302)
    assert token = get_session(redeemed, "sanctum_session_token")
    assert %{http_only: true} = cookie_session(redeemed)
    assert {:ok, %{client_id: nil}} = Sanctum.Session.load(token)
    assert %{client_id: client_id} = Arca.Repo.get!(Arca.Schemas.Session, answer.session_id)
    assert client_id == ctx.client_id

    again = post(build_conn(), "/auth/device/complete", %{"ticket" => answer.ticket})
    assert again.status == 403
    assert get_session(again, "sanctum_session_token") == nil
  end

  test "a ticket locked before it was spent sets nothing", %{conn: conn, device: device, ctx: ctx} do
    answer = unlocked!(ctx, device.key)
    certificate = device.certificate

    {:ok, lock} =
      Prima.DeviceCert.Challenge.new(
        purpose: :lock,
        home: certificate.audience,
        athanor: certificate.athanor,
        client_id: certificate.client_id,
        device_key: certificate.device_key,
        session_id: answer.session_id
      )

    {:ok, %{locked: true}} =
      Sanctum.DeviceUnlock.lock(ctx, %{"proof" => signed(lock, elem(device.key, 1))})

    conn = post(conn, "/auth/device/complete", %{"ticket" => answer.ticket})
    assert conn.status == 403
    assert get_session(conn, "sanctum_session_token") == nil
    assert Arca.Repo.get(Arca.Schemas.Session, answer.session_id) == nil
  end
end
