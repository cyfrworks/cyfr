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

  test "its check answers what the browser starts with: the stored language and zone, each absent when none is",
       %{ctx: ctx, user: user} do
    # A person who has never opened a screen: Chrome's own.
    assert {:ok, %{}} == BrowserSetting.start(ctx)

    assert :ok = Aqua.put_locale(ctx.user_id, "de-DE")
    assert {:ok, %{"locale" => "de-DE"}} == BrowserSetting.start(ctx)

    assert :ok = Aqua.put_time_zone(ctx.user_id, "Asia/Kolkata")

    assert {:ok, %{"locale" => "de-DE", "time_zone" => "Asia/Kolkata"}} ==
             BrowserSetting.start(ctx)

    # Stored values out of their grammar, or a zone no database knows, are
    # none.
    {:ok, _} = Users.put_prefs(user, %{"locale" => "de_DE", "time_zone" => "Mars/Olympus_Mons"})
    assert {:ok, %{}} == BrowserSetting.start(ctx)

    assert {:ok, false} = BrowserSetting.put(ctx, false)
    assert :turned_off == BrowserSetting.start(ctx)

    assert :turned_off ==
             BrowserSetting.start(%{Sanctum.TestContext.local() | user_id: "usr_nobody_here"})
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

  # Every writer of the preferences takes the one locked read and write
  # (`Sanctum.Tenancy.Users.put_prefs/2`), the zone the daily thread is read
  # in among them (`Aqua.put_time_zone/2`).
  test "a zone write and a browser-setting write made in the same instant both land", %{ctx: ctx} do
    for round <- 1..20 do
      on = rem(round, 2) == 0
      zone = if on, do: "Europe/Lisbon", else: "Asia/Tokyo"

      writers = [
        Task.async(fn -> receive(do: (:go -> Aqua.put_time_zone(ctx.user_id, zone))) end),
        Task.async(fn -> receive(do: (:go -> BrowserSetting.put(ctx, on))) end)
      ]

      Enum.each(writers, &send(&1.pid, :go))
      assert [:ok, {:ok, ^on}] = Task.await_many(writers, 15_000)
      assert %{"time_zone" => ^zone, "aqua_browser" => ^on} = prefs(ctx.user_id), "round #{round}"
    end
  end
end
