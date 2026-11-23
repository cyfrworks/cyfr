# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ReadingTest do
  @moduledoc """
  The person's time zone and language are stored as their own browser
  reports them: one report is one write of both, only their own keys, and
  none while they are unchanged; two devices reporting at once leave one
  device's pair; a value CYFR's one definition refuses, each the vectors'
  person refuses, stores nothing; and a stored value that does not read is
  none.
  """
  use ExUnit.Case, async: false
  alias Sanctum.Tenancy.Users

  @vectors Path.expand("../../../../tests/fixtures/browser_frames.json", __DIR__)
  @external_resource @vectors

  setup do
    Cyfr.Test.Sandbox.setup!()
    n = System.unique_integer([:positive])
    local = Sanctum.TestContext.local(:prism)
    {_ctx, user} = Sanctum.TestContext.person!(%{local | user_id: "local|idp|reading-#{n}"})
    {:ok, user: user}
  end

  defp prefs(user_id) do
    {:ok, user} = Users.get(user_id)
    Users.prefs(user)
  end

  # The writes of a person's row while `fun` runs, from the repo's own
  # report of each query.
  defp writes_of_row(user_id, fun) do
    test = self()
    handler = "reading-writes-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measures, %{query: query, params: params}, _config ->
          if query =~ ~r/\AUPDATE\b.*\busers\b/s and user_id in params,
            do: send(test, {:wrote, query})
        end,
        nil
      )

    try do
      result = fun.()
      writes = Stream.repeatedly(fn -> receive(do: ({:wrote, q} -> q), after: (0 -> nil)) end)
      {result, writes |> Enum.take_while(& &1) |> length()}
    after
      :telemetry.detach(handler)
    end
  end

  test "a report is one write of both, only their own keys, and none while they are unchanged", %{
    user: user
  } do
    {:ok, _} = Users.put_prefs(user, %{"mode" => "dark"})

    assert {:ok, 1} =
             writes_of_row(user.id, fn ->
               Aqua.put_reading(user.id, %{"time_zone" => "Asia/Tokyo", "locale" => "ja-JP"})
             end)

    assert prefs(user.id) == %{"mode" => "dark", "time_zone" => "Asia/Tokyo", "locale" => "ja-JP"}

    assert {:ok, 0} =
             writes_of_row(user.id, fn ->
               Aqua.put_reading(user.id, %{"time_zone" => "Asia/Tokyo", "locale" => "ja-JP"})
             end)

    assert {:ok, 1} =
             writes_of_row(user.id, fn ->
               Aqua.put_reading(user.id, %{"time_zone" => "Asia/Tokyo", "locale" => "en-GB"})
             end)

    assert prefs(user.id)["locale"] == "en-GB"
  end

  test "two devices reporting at once leave one device's pair, never a mix", %{user: user} do
    pairs = [
      %{"time_zone" => "Asia/Tokyo", "locale" => "ja-JP"},
      %{"time_zone" => "Europe/Lisbon", "locale" => "pt-PT"}
    ]

    for round <- 1..20 do
      tasks =
        for pair <- pairs,
            do: Task.async(fn -> receive(do: (:go -> Aqua.put_reading(user.id, pair))) end)

      Enum.each(tasks, &send(&1.pid, :go))
      assert Enum.all?(Task.await_many(tasks), &(&1 == :ok)), "round #{round}"
      stored = Map.take(prefs(user.id), ["time_zone", "locale"])
      assert stored in pairs, "round #{round}: #{inspect(stored)}"
    end
  end

  test "a value CYFR's one definition refuses stores nothing, each the vectors refuse", %{
    user: user
  } do
    assert :ok = Aqua.put_reading(user.id, %{"time_zone" => "Asia/Tokyo", "locale" => "ja-JP"})
    refused = (@vectors |> File.read!() |> Jason.decode!())["person"]["refuse"]

    for %{"name" => name, "person" => person} <- refused,
        Map.keys(person) -- ["time_zone", "locale"] == [] do
      assert {:error, :invalid} = Aqua.put_reading(user.id, person), name

      assert Map.take(prefs(user.id), ["time_zone", "locale"]) == %{
               "time_zone" => "Asia/Tokyo",
               "locale" => "ja-JP"
             },
             name
    end
  end

  test "a stored value that does not read, or none, is none" do
    assert Aqua.Reading.locale(%{}) == nil
    assert Aqua.Reading.locale(%{"locale" => "de_DE"}) == nil
    assert Aqua.Reading.locale(%{"locale" => 5}) == nil
    assert Aqua.Reading.locale(%{"locale" => "zh-Hant-TW"}) == "zh-Hant-TW"
  end
end
