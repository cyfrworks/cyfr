# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DeviceUnlockReview353EdgesTest do
  use PrismWeb.ConnCase, async: false
  import Cyfr.Test.ProtectedDevice
  import Ecto.Query
  alias Prima.DeviceCert.Challenge
  alias Sanctum.{Context, DeviceUnlock}
  @token String.duplicate("53", 32)

  setup do
    Arca.Cache.init()
    Prima.Test.RateLimiter.reset!()
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)
    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)
    Sanctum.Test.Newcomers.directory!()
    Arca.Repo.delete_all(Arca.Schemas.User)
    :ok
  end

  test "review353 a dangling device reference grants no session" do
    device = enrolled!(@token)
    ctx = connected!(device)
    answer = unlocked!(ctx, device.key)
    {:ok, %{token: token}} = DeviceUnlock.redeem(answer.ticket)

    Arca.Repo.update_all(from(s in Arca.Schemas.Session, where: s.id == ^answer.session_id),
      set: [client_id: "pcl_missing"]
    )

    assert {:error, :invalid_session} = Sanctum.Session.load(token)
  end

  test "review353 certificate renewal never revives a retired browser session" do
    device = enrolled!(@token)
    ctx = connected!(device)
    answer = unlocked!(ctx, device.key)
    {:ok, %{token: token}} = DeviceUnlock.redeem(answer.ticket)
    actor = Context.actor(ctx)
    {:ok, old} = Arca.DeviceCertificates.current(actor, ctx.client_id)
    {:ok, _} = Arca.DeviceCertificates.revoke(actor, old.id)
    assert {:error, :invalid_session} = Sanctum.Session.load(token)

    {:ok, challenge} =
      Challenge.new(
        purpose: :renew,
        home: device.certificate.audience,
        athanor: ctx.athanor_id,
        client_id: ctx.client_id,
        device_key: elem(device.key, 0),
        nonce: :crypto.strong_rand_bytes(32),
        now: System.system_time(:millisecond)
      )

    proof = Prima.DeviceCert.Proof.sign(challenge, elem(device.key, 1))

    {:ok, renewal} =
      Sanctum.DeviceCerts.verify_connect(
        %{client_id: ctx.client_id, certificate: device.certificate, source: "198.51.100.43"},
        proof,
        challenge
      )

    assert {:ok, _} =
             Sanctum.Pairing.renew(renewal, %{
               client_id: ctx.client_id,
               device_key: elem(device.key, 0),
               proof: Prima.DeviceCert.Proof.encode(proof)
             })

    assert {:error, :invalid_session} = Sanctum.Session.load(token)
  end
end
