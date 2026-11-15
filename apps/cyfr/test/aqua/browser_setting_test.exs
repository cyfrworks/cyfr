# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.BrowserSettingTest do
  @moduledoc """
  The person's browser setting (`Aqua.BrowserSetting`): one value of their
  preferences, on unless they turned it off, off for a value that does
  not read, and written as a merge into the preferences as the store
  holds them, so another preference written meanwhile, a time zone among
  them, is kept and a stale write of another key brings nothing back.
  """
  use ExUnit.Case, async: false

  alias Aqua.BrowserSetting
  alias Sanctum.Tenancy.Users

  setup do
    Cyfr.Test.Sandbox.setup!()
    Arca.Cache.init()

    {:ok, user} =
      Sanctum.Test.People.linked(%{id: "setting-person", provider: "local", verified: true})

    athanor = Sanctum.Test.People.athanor!(user)

    ctx = %{
      Sanctum.TestContext.local()
      | user_id: user.id,
        athanor_id: athanor.id,
        permissions: MapSet.new([:*])
    }

    {:ok, ctx: ctx, user: user}
  end

  defp prefs(user_id) do
    {:ok, user} = Users.get(user_id)
    Users.prefs(user)
  end

  test "an absent value reads as on, the default", %{ctx: ctx} do
    refute Map.has_key?(prefs(ctx.user_id), "aqua_browser")
    assert {:ok, true} = BrowserSetting.allowed?(ctx)
  end

  test "the person turns it off and on", %{ctx: ctx} do
    assert {:ok, false} = BrowserSetting.put(ctx, false)
    assert {:ok, false} = BrowserSetting.allowed?(ctx)
    assert prefs(ctx.user_id)["aqua_browser"] == false

    assert {:ok, true} = BrowserSetting.put(ctx, true)
    assert {:ok, true} = BrowserSetting.allowed?(ctx)
  end

  test "a value that is not a boolean reads as off", %{ctx: ctx, user: user} do
    {:ok, _} = Users.put_prefs(user, %{"aqua_browser" => "yes"})
    assert {:ok, false} = BrowserSetting.allowed?(ctx)
  end

  test "a person this server does not hold may not use it" do
    stranger = %{Sanctum.TestContext.local() | user_id: "usr_nobody_here"}
    assert {:ok, false} = BrowserSetting.allowed?(stranger)
  end

  test "a write keeps every other preference, and a stale write of another key brings nothing back",
       %{ctx: ctx, user: user} do
    {:ok, _} = Users.put_prefs(user, %{"time_zone" => "Europe/Lisbon", "mode" => "dark"})

    # Read before the person turned the browser off.
    {:ok, stale} = Users.get(ctx.user_id)
    assert {:ok, false} = BrowserSetting.put(ctx, false)

    # Another writer's change made from what it read before.
    {:ok, _} = Users.put_prefs(stale, %{"time_zone" => "Asia/Tokyo"})

    assert prefs(ctx.user_id) == %{
             "time_zone" => "Asia/Tokyo",
             "mode" => "dark",
             "aqua_browser" => false
           }

    assert {:ok, false} = BrowserSetting.allowed?(ctx)
  end
end
