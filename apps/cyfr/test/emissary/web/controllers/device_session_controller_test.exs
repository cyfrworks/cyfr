# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.DeviceSessionControllerTest do
  @moduledoc """
  A protected command line's session (`POST /device/session`,
  `tests/fixtures/device_unlock.json`, `exchange.http.device_session`): the
  unlock's ticket spent once for a bearer token of a session bound to the
  device, which the device's lock ends; no cookie read or set; a ticket
  spent, unknown, locked first or of a revoked device answers
  `ticket_refused` and creates nothing.
  """

  use Emissary.Web.ConnCase, async: false

  import Cyfr.Test.ProtectedDevice

  @token String.duplicate("5e", 32)
  @vectors Path.expand("../../../../../../tests/fixtures/device_unlock.json", __DIR__)

  setup do
    Arca.Cache.init()
    Prima.Test.RateLimiter.reset!()
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)
    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)
    Sanctum.Test.Newcomers.directory!()
    Arca.Repo.delete_all(Arca.Schemas.User)
    device = enrolled!(@token)
    %{device: device, ctx: connected!(device)}
  end

  defp entry, do: (@vectors |> File.read!() |> Jason.decode!())["exchange"]["http"]

  defp spend(ticket) do
    %{"device_session" => %{"method" => "POST", "path" => path}} = entry()

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(%{"ticket" => ticket}))
  end

  defp lock!(device, ctx, session_id) do
    certificate = device.certificate

    {:ok, lock} =
      Prima.DeviceCert.Challenge.new(
        purpose: :lock,
        home: certificate.audience,
        athanor: certificate.athanor,
        client_id: certificate.client_id,
        device_key: certificate.device_key,
        session_id: session_id
      )

    {:ok, %{locked: true}} =
      Sanctum.DeviceUnlock.lock(ctx, %{"proof" => signed(lock, elem(device.key, 1))})
  end

  test "a ticket spent once answers the token of a session bound to the device, and no cookie", %{
    device: device,
    ctx: ctx
  } do
    http = entry()
    answer = unlocked!(ctx, device.key)
    conn = spend(answer.ticket)

    assert %{"session_token" => token, "expires_at" => expires_at} =
             body = json_response(conn, 200)

    assert Enum.sort(Map.keys(body)) == http["device_session"]["response"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "set-cookie") == []
    assert is_integer(expires_at)
    assert expires_at <= System.system_time(:millisecond) + 60_000 + 1_000

    # A bearer of the device's own session, as a command's MCP call carries it.
    # Its context is the session's, never the device's: the client is the
    # session row's dependency.
    assert {:ok, %Sanctum.Context{user_id: user_id, client_id: nil}} =
             Sanctum.Caller.establish({:session, token}, [])

    assert user_id == device.certificate.subject.user_id
    client_id = ctx.client_id
    assert %{client_id: ^client_id} = Arca.Repo.get!(Arca.Schemas.Session, answer.session_id)

    # Spent: a second time nothing.
    assert json_response(spend(answer.ticket), 403) == %{"error" => "ticket_refused"}

    # The device's lock ends the token's session.
    lock!(device, ctx, answer.session_id)
    assert {:error, _gone} = Sanctum.Caller.establish({:session, token}, [])
  end

  test "a ticket locked before it was spent, of a revoked device, or no ticket at all, creates nothing",
       %{device: device, ctx: ctx} do
    answer = unlocked!(ctx, device.key)
    lock!(device, ctx, answer.session_id)
    assert json_response(spend(answer.ticket), 403) == %{"error" => "ticket_refused"}
    assert Arca.Repo.get(Arca.Schemas.Session, answer.session_id) == nil

    answer = unlocked!(ctx, device.key)
    actor = Prima.Actor.in_athanor(device.certificate.athanor)
    {:ok, _revoked} = Arca.PairedClients.revoke(actor, device.certificate.client_id)
    assert json_response(spend(answer.ticket), 403) == %{"error" => "ticket_refused"}
    assert Arca.Repo.get(Arca.Schemas.Session, answer.session_id) == nil

    assert json_response(
             spend(Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)),
             403
           ) ==
             %{"error" => "ticket_refused"}

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/device/session", Jason.encode!(%{}))

    assert json_response(conn, 422) == %{"error" => "invalid_request"}
  end

  test "the request log keeps neither the ticket nor the token" do
    assert Prima.Sanitizer.sanitize(%{"ticket" => "t", "session_token" => "s"}) ==
             %{"ticket" => "[REDACTED]", "session_token" => "[REDACTED]"}
  end
end
