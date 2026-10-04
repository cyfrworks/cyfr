# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.InstanceEntryUsageTest do
  use ExUnit.Case, async: false

  require Ecto.Query

  alias Arca.InstanceEntryUsage, as: Usage

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    platform = Arca.Test.Actor.platform()
    {:ok, platform: platform, entry: entry!(platform)}
  end

  defp entry!(platform) do
    {:ok, entry} =
      Arca.InstanceEntries.put(platform, %{
        name: "openai-#{System.unique_integer([:positive])}",
        kind: "api_key",
        provider_hint: "openai.com",
        destination:
          ~s({"hosts":["api.openai.com"],"methods":["POST"],"paths":["/v1/"],"scheme":"https"}),
        sealed_payload: "sealed",
        binding_digest: "sha256:i0",
        audience: "everyone",
        created_by: "usr_admin"
      })

    entry
  end

  defp today, do: DateTime.to_date(Arca.ServerMetaStorage.now!())

  defp tomorrow_midnight,
    do: DateTime.new!(Date.add(today(), 1), ~T[00:00:00.000000], "Etc/UTC")

  test "each claim counts the person's day and the entry's total", %{
    platform: platform,
    entry: entry
  } do
    caps = %{person_daily: 10, total_daily: 1_000}

    assert {:ok, %{person: 1, total: 1, day: day}} =
             Usage.claim(platform, entry.id, "usr_alice", caps)

    assert day == today()
    assert {:ok, %{person: 2, total: 2}} = Usage.claim(platform, entry.id, "usr_alice", caps)
    assert {:ok, %{person: 1, total: 3}} = Usage.claim(platform, entry.id, "usr_bob", caps)

    assert {:ok, %{people: people, totals: [%{count: 3}]}} = Usage.usage(platform, entry.id, 1)

    assert Enum.sort_by(people, & &1.user_id) == [
             %{user_id: "usr_alice", day: day, count: 2},
             %{user_id: "usr_bob", day: day, count: 1}
           ]
  end

  test "a claim at the person's cap is refused with the day's reset, and counts nothing",
       %{platform: platform, entry: entry} do
    caps = %{person_daily: 2, total_daily: 1_000}

    assert {:ok, _} = Usage.claim(platform, entry.id, "usr_alice", caps)
    assert {:ok, _} = Usage.claim(platform, entry.id, "usr_alice", caps)

    reset = tomorrow_midnight()

    assert {:error, {:connection_cap, ^reset}} =
             Usage.claim(platform, entry.id, "usr_alice", caps)

    # Another person's day is their own.
    assert {:ok, %{person: 1, total: 3}} = Usage.claim(platform, entry.id, "usr_bob", caps)
    assert {:ok, %{totals: [%{count: 3}]}} = Usage.usage(platform, entry.id, 1)
  end

  test "a claim at the entry's cap is refused with the reset, whoever asks", %{
    platform: platform,
    entry: entry
  } do
    caps = %{person_daily: 1_000, total_daily: 2}

    assert {:ok, _} = Usage.claim(platform, entry.id, "usr_alice", caps)
    assert {:ok, _} = Usage.claim(platform, entry.id, "usr_bob", caps)

    reset = tomorrow_midnight()

    assert {:error, {:connection_cap, ^reset}} =
             Usage.claim(platform, entry.id, "usr_carol", caps)

    assert {:ok, %{people: people}} = Usage.usage(platform, entry.id, 1)
    refute Enum.any?(people, &(&1.user_id == "usr_carol" and &1.count > 0))
  end

  test "a cap of 0 admits no use", %{platform: platform, entry: entry} do
    assert {:error, {:connection_cap, _}} =
             Usage.claim(platform, entry.id, "usr_alice", %{person_daily: 0, total_daily: 1_000})

    assert {:error, {:connection_cap, _}} =
             Usage.claim(platform, entry.id, "usr_alice", %{person_daily: 1_000, total_daily: 0})

    assert {:ok, %{people: [], totals: []}} = Usage.usage(platform, entry.id, 1)
  end

  # No claim is uncapped: an entry's unset cap takes its platform setting's
  # default above the store, so `nil` is refused here, as is anything else
  # that is not a cap the entry's columns can hold.
  test "a cap that is nil, or not an integer within the column's range, is refused",
       %{platform: platform, entry: entry} do
    max = Arca.Schemas.InstanceEntry.max_cap()

    Arca.Test.QueryCounter.assert_queries(0, fn ->
      for caps <- [
            %{person_daily: nil, total_daily: 1_000},
            %{person_daily: 1_000, total_daily: nil},
            %{person_daily: nil, total_daily: nil},
            %{person_daily: -1, total_daily: 1_000},
            %{person_daily: 1_000, total_daily: max + 1},
            %{person_daily: "10", total_daily: 1_000},
            %{person_daily: 1.5, total_daily: 1_000}
          ] do
        assert {:error, {:invalid, %{caps: _}}} =
                 Usage.claim(platform, entry.id, "usr_alice", caps),
               inspect(caps)
      end
    end)

    assert {:ok, %{people: [], totals: []}} = Usage.usage(platform, entry.id, 1)

    assert {:ok, %{person: 1, total: 1}} =
             Usage.claim(platform, entry.id, "usr_alice", %{person_daily: max, total_daily: max})
  end

  test "only the platform's actor counts or reads use", %{entry: entry} do
    tenant = Arca.Test.Actor.local()
    caps = %{person_daily: 1_000, total_daily: 1_000}

    assert {:error, :cross_tenant} = Usage.claim(tenant, entry.id, "usr_alice", caps)
    assert {:error, :cross_tenant} = Usage.usage(tenant, entry.id, 1)
    assert {:error, :cross_tenant} = Usage.used_today(tenant, entry.id, "usr_alice")
    assert {:error, :cross_tenant} = Usage.sweep(tenant)
  end

  test "a person's use today is their own day row of that entry, and no one else's",
       %{platform: platform, entry: entry} do
    other = entry!(platform)
    caps = %{person_daily: 10, total_daily: 1_000}

    assert {:ok, 0} = Usage.used_today(platform, entry.id, "usr_alice")

    for _ <- 1..2, do: {:ok, _} = Usage.claim(platform, entry.id, "usr_alice", caps)
    {:ok, _} = Usage.claim(platform, entry.id, "usr_bob", caps)
    {:ok, _} = Usage.claim(platform, other.id, "usr_alice", caps)

    # Alice's two on this entry: not Bob's, not the entry's total of three,
    # and not her use of the other entry.
    assert {:ok, 2} = Usage.used_today(platform, entry.id, "usr_alice")
    assert {:ok, 1} = Usage.used_today(platform, entry.id, "usr_bob")
    assert {:ok, 1} = Usage.used_today(platform, other.id, "usr_alice")
    assert {:ok, 0} = Usage.used_today(platform, other.id, "usr_bob")

    # A count of an earlier day is not today's.
    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.InstanceEntryUsage, [
        %{
          instance_entry_id: other.id,
          user_id: "usr_bob",
          day: Date.add(today(), -1),
          count: 7,
          updated_at: DateTime.utc_now()
        }
      ])

    assert {:ok, 0} = Usage.used_today(platform, other.id, "usr_bob")

    # The entry's total is keyed by no person, and is never read as one.
    assert {:error, {:invalid, %{user_id: _}}} = Usage.used_today(platform, entry.id, "")
  end

  test "the sweep removes the days older than thirty-five", %{platform: platform, entry: entry} do
    now = DateTime.utc_now()

    rows =
      for {who, days_ago} <- [{"usr_old", 36}, {"usr_edge", 35}, {"usr_new", 0}] do
        %{
          instance_entry_id: entry.id,
          user_id: who,
          day: Date.add(today(), -days_ago),
          count: 1,
          updated_at: now
        }
      end

    {3, _} = Arca.Repo.insert_all(Arca.Schemas.InstanceEntryUsage, rows)

    assert {:ok, 1} = Usage.sweep(platform)

    left =
      Arca.Repo.all(
        Ecto.Query.from(u in Arca.Schemas.InstanceEntryUsage,
          where: u.instance_entry_id == ^entry.id,
          select: u.user_id
        )
      )

    assert Enum.sort(left) == ["usr_edge", "usr_new"]
    assert Usage.kept_days() == 35
  end
end

defmodule Arca.InstanceEntryUsageRaceTest do
  @moduledoc """
  Claims on connections of their own: inside the sandbox one shared
  connection would serialize the members the case is about.
  """

  use ExUnit.Case, async: false

  require Ecto.Query

  alias Arca.InstanceEntryUsage, as: Usage
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    platform = Arca.Test.Actor.platform()

    entry =
      unboxed(fn ->
        {:ok, entry} =
          Arca.InstanceEntries.put(platform, %{
            name: "race-#{System.unique_integer([:positive])}",
            kind: "api_key",
            provider_hint: "openai.com",
            destination:
              ~s({"hosts":["api.openai.com"],"methods":["POST"],"paths":["/v1/"],"scheme":"https"}),
            sealed_payload: "sealed",
            binding_digest: "sha256:i0",
            audience: "everyone",
            created_by: "usr_admin"
          })

        entry
      end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(
          Ecto.Query.from(u in Arca.Schemas.InstanceEntryUsage,
            where: u.instance_entry_id == ^entry.id
          )
        )

        Arca.Repo.delete_all(
          Ecto.Query.from(i in Arca.Schemas.InstanceEntry, where: i.id == ^entry.id)
        )
      end)
    end)

    {:ok, platform: platform, entry: entry}
  end

  test "two members claiming the last request of a person's day admit one", %{
    platform: platform,
    entry: entry
  } do
    caps = %{person_daily: 1, total_daily: 1_000}

    results =
      for _member <- 1..2 do
        Task.async(fn ->
          unboxed(fn -> Usage.claim(platform, entry.id, "usr_alice", caps) end)
        end)
      end
      |> Task.await_many(30_000)

    assert [{:error, {:connection_cap, _}}, {:ok, %{person: 1, total: 1}}] =
             Enum.sort_by(results, &match?({:ok, _}, &1))
  end

  test "two people racing for one remaining request of the entry's day admit one", %{
    platform: platform,
    entry: entry
  } do
    caps = %{person_daily: 1_000, total_daily: 1}

    results =
      for person <- ["usr_alice", "usr_bob"] do
        Task.async(fn -> unboxed(fn -> Usage.claim(platform, entry.id, person, caps) end) end)
      end
      |> Task.await_many(30_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:connection_cap, _}}, &1)) == 1

    assert {:ok, %{totals: [%{count: 1}]}} =
             unboxed(fn -> Usage.usage(platform, entry.id, 1) end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
end
