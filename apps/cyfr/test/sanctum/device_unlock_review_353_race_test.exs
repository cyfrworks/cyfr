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
    Athanor,
    DirectoryHead,
    ServerAllowlistEntry
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
    device = unboxed(fn -> enrolled!(@token) end)
    user_id = device.user.id
    identifier = device.account.identifier

    on_exit(fn ->
      unboxed(fn ->
        for schema <- [Session, DeviceCertificate, PairedClient, PersonIdentity] do
          Arca.Repo.delete_all(from(r in schema, where: r.user_id == ^user_id))
        end

        Arca.Repo.delete_all(from(h in DirectoryHead, where: h.identifier == ^identifier))
        Arca.Repo.delete_all(from(e in ServerAllowlistEntry, where: e.value == ^identifier))

        Arca.Repo.delete_all(from(a in Athanor, where: a.owner_user_id == ^user_id))
        Arca.Repo.delete_all(from(u in User, where: u.id == ^user_id))
      end)
    end)

    ctx = unboxed(fn -> connected!(device) end)
    answer = unboxed(fn -> unlocked!(ctx, device.key) end)
    %{device: device, ctx: ctx, answer: answer}
  end

  test "review353 lock between ticket take and insert refuses redemption", %{
    device: device,
    ctx: ctx,
    answer: answer
  } do
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
    send(pid, :continue_redemption)
    result = Task.await(task, 10000)
    :telemetry.detach(handler)
    row = unboxed(fn -> Arca.Repo.get(Session, answer.session_id) end)

    assert match?({:error, _}, result) and row == nil,
           "lock completed before insertion, redemption=#{inspect(result)}, persisted_session=#{row != nil}"
  end
end
