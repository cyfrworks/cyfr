# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DeviceUnlockReview353Test do
  use PrismWeb.ConnCase, async: false
  import Cyfr.Test.ProtectedDevice
  import Ecto.Query
  alias Sanctum.DeviceUnlock

  @token String.duplicate("51", 32)

  setup do
    Arca.Cache.init()
    Prima.Test.RateLimiter.reset!()
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)
    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)
    Sanctum.Test.Newcomers.directory!()
    Arca.Repo.delete_all(Arca.Schemas.User)
    device = enrolled!(@token)
    ctx = connected!(device)
    answer = unlocked!(ctx, device.key)
    %{device: device, ctx: ctx, answer: answer}
  end

  test "review353 a lost member cannot slide a device session", %{ctx: ctx, answer: answer} do
    {:ok, _session} = DeviceUnlock.redeem(answer.ticket)
    at = DateTime.add(DateTime.utc_now(), 10, :second)

    Arca.Repo.update_all(from(s in Arca.Schemas.Session, where: s.id == ^answer.session_id),
      set: [expires_at: at]
    )

    key = {Arca.ControlPlane, :standing}
    saved = :persistent_term.get(key, :absent)

    on_exit(fn ->
      if saved == :absent, do: :persistent_term.erase(key), else: :persistent_term.put(key, saved)
    end)

    Arca.ControlPlane.record(:lost)
    result = DeviceUnlock.slide(ctx, [answer.session_id])
    after_slide = Arca.Repo.get!(Arca.Schemas.Session, answer.session_id).expires_at

    assert match?({:error, _}, result) and after_slide == at,
           "lost ownership returned #{inspect(result)} and moved expiry from #{inspect(at)} to #{inspect(after_slide)}"
  end
end
