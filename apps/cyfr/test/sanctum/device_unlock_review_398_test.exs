# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DeviceUnlockReview398Test do
  use PrismWeb.ConnCase, async: false
  import Cyfr.Test.ProtectedDevice
  import Ecto.Query
  alias Sanctum.DeviceUnlock
  alias Prima.DeviceCert.Challenge

  @token String.duplicate("61", 32)

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

  @tag :review398_finding
  test "review398 a lock after the challenge cannot be undone by ticket issuance", %{
    device: device,
    ctx: ctx
  } do
    {:ok, %{challenge: unlock}} = DeviceUnlock.unlock(ctx, %{})

    {:ok, lock} =
      Challenge.new(
        purpose: :lock,
        home: unlock.home,
        athanor: unlock.athanor,
        client_id: unlock.client_id,
        device_key: unlock.device_key,
        session_id: unlock.session_id
      )

    pending_unlock = signed(unlock, elem(device.key, 1))

    assert {:ok, %{locked: true}} =
             DeviceUnlock.lock(ctx, %{"proof" => signed(lock, elem(device.key, 1))})

    issuance = DeviceUnlock.unlock(ctx, %{"proof" => pending_unlock})

    redemption =
      case issuance do
        {:ok, ticket} -> DeviceUnlock.redeem(ticket.ticket)
        error -> error
      end

    assert match?({:error, _}, redemption),
           "a completed lock of #{unlock.session_id} was undone: issuance=#{inspect(issuance)} redemption=#{inspect(redemption)}"

    assert Arca.Repo.get(Arca.Schemas.Session, unlock.session_id) == nil
  end

  test "review398 a reservation gives no usable token and is not slid past its ticket", %{
    device: device,
    ctx: ctx
  } do
    answer = unlocked!(ctx, device.key)
    row = Arca.Repo.get!(Arca.Schemas.Session, answer.session_id)
    assert row.provider == "unlock_reserved"
    assert {:error, :invalid_session} = Sanctum.Session.load(b64(row.token_hash))
    assert {:error, :invalid_session} = Sanctum.Session.load(answer.ticket)
    assert {:ok, [id]} = DeviceUnlock.slide(ctx, [answer.session_id])
    assert id == answer.session_id
    assert Arca.Repo.get!(Arca.Schemas.Session, id).expires_at == row.expires_at

    Arca.Repo.update_all(from(s in Arca.Schemas.Session, where: s.id == ^id),
      set: [expires_at: DateTime.add(Arca.ServerMetaStorage.now!(), -1, :second)]
    )

    assert {:error, :invalid_ticket} = DeviceUnlock.redeem(answer.ticket)
    assert {:ok, []} = DeviceUnlock.slide(ctx, [id])
  end

  @tag :review398_finding
  test "review398 client revocation retains the hashes needed to invalidate its sessions", %{
    device: device,
    ctx: ctx
  } do
    answer = unlocked!(ctx, device.key)
    {:ok, %{token: token}} = DeviceUnlock.redeem(answer.ticket)
    {:ok, row} = Arca.PairedClients.revoke(Sanctum.Context.actor(ctx), ctx.client_id)
    assert Arca.Repo.get(Arca.Schemas.Session, answer.session_id) == nil

    assert Sanctum.Session.token_hash(token) in row.revoked_session_hashes,
           "revocation deleted the device session but returned #{inspect(row.revoked_session_hashes)} for memo invalidation"
  end

  test "review398 certificate revocation keeps another client's session and respects the actor",
       %{device: device, ctx: ctx} do
    first = unlocked!(ctx, device.key)
    {:ok, %{token: first_token}} = DeviceUnlock.redeem(first.ticket)
    actor = Sanctum.Context.actor(ctx)
    pair = key()

    {:ok, client} =
      Arca.PairedClients.enroll(
        actor,
        %{
          user_id: ctx.user_id,
          source_kind: "device_cert",
          source_id: "req_second",
          device_public_key: elem(pair, 0),
          holder_kind: "chip",
          display_name: "Second"
        }, first_method: :mark, also: &Sanctum.Pairing.certify_first(actor, &1))

    {:ok, cert} = Arca.DeviceCertificates.current(actor, client.id)
    {:ok, certificate} = cert.certificate |> Jason.decode!() |> Prima.DeviceCert.decode()
    other = connected!(%{key: pair, certificate: certificate})
    second = unlocked!(other, pair)
    {:ok, %{token: second_token}} = DeviceUnlock.redeem(second.ticket)
    {:ok, mine} = Arca.DeviceCertificates.current(actor, ctx.client_id)

    assert {:error, :not_found} =
             Arca.DeviceCertificates.revoke(Prima.Actor.in_athanor("ath_other"), mine.id)

    assert {:ok, _} = Sanctum.Session.load(first_token)
    assert {:ok, _} = Arca.DeviceCertificates.revoke(actor, mine.id)
    assert {:error, :invalid_session} = Sanctum.Session.load(first_token)
    assert {:ok, _} = Sanctum.Session.load(second_token)
  end
end
