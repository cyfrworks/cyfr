# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.DayTest do
  @moduledoc """
  The person's day is the date in their stored zone, UTC without one or
  for one the zone database does not know, and the current daily thread
  is that date's, made once however many ask for it at once. A changed
  zone moves the next send to the daily thread of the date in the new
  zone, made or used again, and moves nothing made before it. Midnight is
  simulated by the zone, never the clock: at any instant `Etc/GMT+12` and
  `Pacific/Kiritimati` are on different dates.
  """

  use ExUnit.Case, async: false

  alias Aqua.Providers.Thread, as: Tool
  alias Arca.ThreadStorage, as: Threads
  alias Sanctum.Tenancy.Users

  @west "Etc/GMT+12"
  @east "Pacific/Kiritimati"
  # A name in the browser's grammar that no zone database knows.
  @unknown "Mars/Olympus_Mons"

  setup do
    Cyfr.Test.Sandbox.setup!()

    # A person of their own, working in their own filled athanor, so a
    # send there starts a turn; the turns stop with the test.
    n = System.unique_integer([:positive])
    local = Sanctum.TestContext.local(:prism)
    {ctx, user} = Sanctum.TestContext.person!(%{local | user_id: "local|idp|day-#{n}"})
    ctx = %{ctx | athanor_id: Sanctum.Test.People.athanor!(user).id}
    Sanctum.TestContext.ready!(ctx.athanor_id)
    Cyfr.Test.Sandbox.stop_work_on_exit()
    {:ok, ctx: ctx, user: user, actor: Sanctum.Context.actor(ctx)}
  end

  # The date in `zone` around `fun`: the one before and the one after, so
  # a midnight passing during the call is no failure.
  defp around(zone, fun) do
    before = date_in(zone)
    result = fun.()
    {result, Enum.uniq([before, date_in(zone)])}
  end

  defp date_in(zone) do
    {:ok, now} = DateTime.now(zone, Tz.TimeZoneDatabase)
    DateTime.to_date(now)
  end

  defp prefs(user_id) do
    {:ok, user} = Users.get(user_id)
    Users.prefs(user)
  end

  defp send!(ctx, text) do
    assert {:ok, %{accepted: true, message_id: message_id, thread: thread_id}} =
             Tool.handle("thread", ctx, %{
               "action" => "send",
               "message" => text,
               "agent" => "aqua"
             })

    {thread_id, message_id}
  end

  defp daily_rows(actor), do: Threads.list(actor, kind: "daily")

  test "callers racing for a new day make one daily thread, and every one is answered it", %{
    ctx: ctx,
    actor: actor
  } do
    {answers, days} =
      around("UTC", fn ->
        1..8
        |> Enum.map(fn _ -> Task.async(fn -> Aqua.Day.current(ctx) end) end)
        |> Enum.map(&Task.await(&1, 15_000))
      end)

    assert [{:ok, %{id: id, day: day}} | _] = answers
    assert Enum.all?(answers, &match?({:ok, %{id: ^id}}, &1)), inspect(answers)
    assert day in days
    assert [%{id: ^id}] = daily_rows(actor)

    # The send that follows joins it.
    {joined, _message} = send!(ctx, "good morning")
    assert joined == id
    assert [%{id: ^id}] = daily_rows(actor)
  end

  test "after a zone change the next send joins the daily thread of the new zone's date, made or used again, and moves nothing made before",
       %{ctx: ctx, user: user, actor: actor} do
    :ok = Aqua.Day.put_zone(user.id, @west)
    {{west_id, first_message}, west_days} = around(@west, fn -> send!(ctx, "in the west") end)
    {:ok, west} = Threads.get(actor, west_id)
    assert west.day in west_days
    assert west.title == Date.to_iso8601(west.day)
    held = Threads.messages(actor, west_id) |> Enum.map(& &1.id)
    assert first_message in held

    # The zone moves past midnight: the next send is a new date's.
    :ok = Aqua.Day.put_zone(user.id, @east)
    {{east_id, east_message}, east_days} = around(@east, fn -> send!(ctx, "in the east") end)
    refute east_id == west_id
    {:ok, east} = Threads.get(actor, east_id)
    assert east.day in east_days
    refute east.day == west.day

    # What the earlier day held stays there, under its date and title.
    assert {:ok, %{day: day, title: title}} = Threads.get(actor, west_id)
    assert {day, title} == {west.day, west.title}
    stayed = Threads.messages(actor, west_id) |> Enum.map(& &1.id)
    assert held -- stayed == []
    refute east_message in stayed
    assert east_message in (Threads.messages(actor, east_id) |> Enum.map(& &1.id))
    refute first_message in (Threads.messages(actor, east_id) |> Enum.map(& &1.id))

    # Back in the first zone, the send joins the daily thread that exists
    # for that date, unless its midnight passed meanwhile.
    :ok = Aqua.Day.put_zone(user.id, @west)
    {{again_id, _message}, again_days} = around(@west, fn -> send!(ctx, "west again") end)
    {:ok, again} = Threads.get(actor, again_id)
    assert again.day in again_days
    if again.day == west.day, do: assert(again_id == west_id)

    # No date holds two daily threads.
    days = Enum.map(daily_rows(actor), & &1.day)
    assert days == Enum.uniq(days)
  end

  test "a send in a zone uses the daily thread already made for that date", %{
    ctx: ctx,
    user: user,
    actor: actor
  } do
    :ok = Aqua.Day.put_zone(user.id, @east)
    {:ok, made} = Threads.daily(actor, date_in(@east))

    {{joined, _message}, sent_days} = around(@east, fn -> send!(ctx, "kept for the day") end)
    {:ok, landed} = Threads.get(actor, joined)
    assert landed.day in sent_days

    # Unless the zone's midnight passed since it was made, the day is the
    # one made, and it is never made twice.
    if landed.day == made.day, do: assert(joined == made.id)
    assert Enum.count(daily_rows(actor), &(&1.day == landed.day)) == 1
  end

  test "a zone is stored only when the day can be read in it, and the person's other prefs stand",
       %{user: user} do
    {:ok, user} = Users.put_prefs(user, %{"theme" => "dark", "mode" => "lite"})

    assert :ok = Aqua.Day.put_zone(user.id, "Europe/Lisbon")

    assert prefs(user.id) == %{
             "theme" => "dark",
             "mode" => "lite",
             "time_zone" => "Europe/Lisbon"
           }

    # A name no database knows, or none at all, is refused and stores
    # nothing: the prefs are as they were.
    for zone <- [@unknown, "not a zone", "../etc/passwd", "", nil, 42] do
      refute Aqua.Day.zone?(zone)
      assert {:error, _} = Aqua.Day.put_zone(user.id, zone)

      assert prefs(user.id) == %{
               "theme" => "dark",
               "mode" => "lite",
               "time_zone" => "Europe/Lisbon"
             }
    end

    assert Aqua.Day.zone?(@west) and Aqua.Day.zone?(@east) and Aqua.Day.zone?("UTC")
  end

  test "the day reads in UTC with no zone stored, with no person, and for a stored zone no database resolves",
       %{ctx: ctx, user: user} do
    assert Aqua.Day.default_zone() == "UTC"

    {today, days} = around("UTC", fn -> Aqua.Day.today(ctx) end)
    assert today in days

    {today, days} = around("UTC", fn -> Aqua.Day.today(%{ctx | user_id: nil}) end)
    assert today in days

    # Stored past the shell's check, as an older row or a zone the
    # database dropped would hold it.
    {:ok, _user} = Users.put_prefs(user, %{"time_zone" => @unknown})
    assert prefs(user.id)["time_zone"] == @unknown

    before = Date.utc_today()
    today = Aqua.Day.today(ctx)
    assert today in [before, Date.utc_today()]

    # A known zone is read in its own date, which the unknown one never is.
    :ok = Aqua.Day.put_zone(user.id, @east)
    {today, days} = around(@east, fn -> Aqua.Day.today(ctx) end)
    assert today in days
  end

  # The zone database is read in one module: the node's own
  # `:time_zone_database` stays unset, so no other code reads zones by
  # accident.
  @root Path.expand("../../../..", __DIR__)

  test "no source but Aqua.Day names the zone database" do
    sources =
      (Path.wildcard(Path.join(@root, "apps/*/lib/**/*")) ++
         Path.wildcard(Path.join(@root, "config/**/*")))
      |> Enum.filter(&File.regular?/1)

    naming =
      for path <- sources,
          text = File.read!(path),
          String.contains?(text, "Tz.") or String.contains?(text, ":time_zone_database"),
          do: Path.relative_to(path, @root)

    # The positive control: the scan reads lib and config, and finds the
    # one module that names it.
    assert "apps/cyfr/lib/aqua/day.ex" in naming
    assert Enum.any?(sources, &String.ends_with?(&1, "config/config.exs"))
    assert naming == ["apps/cyfr/lib/aqua/day.ex"]
  end
end
