# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DeviceUnlockReview353RaceTest do
  use ExUnit.Case, async: false
  import Cyfr.Test.ProtectedDevice
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Sanctum.DeviceUnlock
  alias Prima.DeviceCert.Challenge

  alias Arca.Schemas.{
    User,
    PairedClient,
    DeviceCertificate,
    Session,
    PersonIdentity,
    IdentityAttempt,
    Membership,
    Athanor
  }

  @token String.duplicate("52", 32)

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  setup do
    Arca.Cache.init()
    Prima.Test.RateLimiter.reset!()
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)
    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)
    Sanctum.Test.Newcomers.directory!()
    assert 0 == unboxed(fn -> Arca.Repo.aggregate(User, :count) end)
    identity = Sanctum.Test.Newcomers.identity()
    pair = key()

    on_exit(fn ->
      unboxed(fn ->
        case Arca.Repo.one(
               from(p in PairedClient,
                 where: p.source_id == ^identity.request_id,
                 select: p.user_id
               )
             ) do
          nil ->
            :ok

          user_id ->
            for schema <- [
                  Session,
                  DeviceCertificate,
                  PairedClient,
                  Membership,
                  IdentityAttempt,
                  PersonIdentity
                ] do
              Arca.Repo.delete_all(from(r in schema, where: r.user_id == ^user_id))
            end

            Arca.Repo.delete_all(from(a in Athanor, where: a.owner_user_id == ^user_id))
            Arca.Repo.delete_all(from(u in User, where: u.id == ^user_id))
        end
      end)
    end)

    device =
      unboxed(fn ->
        {:ok, %{challenge: challenge}} =
          DeviceUnlock.enrollment_challenge({:setup, @token}, reported(pair, identity.request_id))

        {:ok, answer} =
          DeviceUnlock.enroll({:setup, @token}, %{
            "proof" => signed(challenge, elem(pair, 1)),
            "name" => identity.name,
            "recovery_secret" => b64(identity.recovery_secret)
          })

        Map.merge(answer, %{key: pair, identity: identity})
      end)

    ctx = unboxed(fn -> connected!(device) end)
    answer = unboxed(fn -> unlocked!(ctx, device.key) end)
    %{device: device, ctx: ctx, answer: answer}
  end

  test "review353 lock between ticket take and insert refuses redemption", tags do
    race(tags, false)
  end

  test "review353 cache loss after lock never permits redemption", tags do
    race(tags, true)
  end

  defp race(%{device: device, ctx: ctx, answer: answer}, forget) do
    {:ok, lock} =
      Challenge.new(
        purpose: :lock,
        home: device.certificate.audience,
        athanor: ctx.athanor_id,
        client_id: ctx.client_id,
        device_key: elem(device.key, 0),
        session_id: answer.session_id
      )

    proof = signed(lock, elem(device.key, 1))
    handler = "review353-#{System.unique_integer([:positive])}"
    test = self()
    on_exit(fn -> :telemetry.detach(handler) end)

    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _, _, _, _ ->
          if Process.get(:review353_redemption, false) do
            Process.put(:review353_redemption, false)
            send(test, {:redemption_taken, self()})

            receive do
              :continue_redemption -> :ok
            after
              5000 -> raise "review353 synchronization timed out"
            end
          end
        end,
        nil
      )

    task =
      Task.async(fn ->
        unboxed(fn ->
          Process.put(:review353_redemption, true)
          DeviceUnlock.redeem(answer.ticket)
        end)
      end)

    on_exit(fn -> send(task.pid, :continue_redemption) end)
    assert_receive {:redemption_taken, pid}, 5000
    assert {:ok, %{locked: true}} = unboxed(fn -> DeviceUnlock.lock(ctx, %{"proof" => proof}) end)
    if forget, do: Arca.Cache.invalidate({:device_locked, answer.session_id})
    send(pid, :continue_redemption)
    result = Task.await(task, 10000)
    :telemetry.detach(handler)
    row = unboxed(fn -> Arca.Repo.get(Session, answer.session_id) end)

    assert match?({:error, _}, result) and row == nil,
           "lock completed before insertion, cache_loss=#{forget}, redemption=#{inspect(result)}, persisted_session=#{row != nil}"
  end
end
