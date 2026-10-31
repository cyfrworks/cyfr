# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ShareUsageTest do
  use ExUnit.Case, async: false

  import Arca.Test.Shares
  import Ecto.Query

  alias Arca.ShareUsage
  alias Arca.Test.QueryCounter

  @everyone %{audience: "everyone", group_id: nil}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    terry = owner!()
    entry = entry!(terry.actor)
    {:ok, terry: terry, entry: entry, share: share!(terry.actor, entry.id)}
  end

  defp capped!(terry, share, person, total) do
    {:ok, _} = Arca.Shares.set_caps(terry.actor, share.id, person, total)
    :ok
  end

  defp today, do: DateTime.to_date(Arca.ServerMetaStorage.now!())

  describe "claim/4" do
    test "an absent cap is no limit, and every use is counted", %{terry: terry, share: share} do
      for n <- 1..3 do
        assert {:ok, %{person: ^n, total: ^n, day: day}} =
                 ShareUsage.claim(terry.actor, share.id, "usr_alice", @everyone)

        assert day == today()
      end

      assert {:ok, %{people: [%{user_id: "usr_alice", count: 3}], totals: [%{count: 3}]}} =
               ShareUsage.usage(terry.actor, share.id, 1)
    end

    test "0 admits no use and counts none", %{terry: terry, share: share} do
      :ok = capped!(terry, share, 0, nil)

      assert {:error, {:connection_cap, reset_at}} =
               ShareUsage.claim(terry.actor, share.id, "usr_alice", @everyone)

      assert reset_at == DateTime.new!(Date.add(today(), 1), ~T[00:00:00.000000], "Etc/UTC")
      assert {:ok, %{people: [], totals: []}} = ShareUsage.usage(terry.actor, share.id, 1)

      :ok = capped!(terry, share, nil, 0)

      assert {:error, {:connection_cap, _}} =
               ShareUsage.claim(terry.actor, share.id, "usr_bea", @everyone)
    end

    test "N admits N a person and N in total that day, each cap on its own",
         %{terry: terry, share: share} do
      :ok = capped!(terry, share, 2, 3)

      assert {:ok, %{person: 1}} = ShareUsage.claim(terry.actor, share.id, "usr_alice", @everyone)
      assert {:ok, %{person: 2}} = ShareUsage.claim(terry.actor, share.id, "usr_alice", @everyone)

      assert {:error, {:connection_cap, _}} =
               ShareUsage.claim(terry.actor, share.id, "usr_alice", @everyone)

      assert {:ok, %{person: 1, total: 3}} =
               ShareUsage.claim(terry.actor, share.id, "usr_bea", @everyone)

      assert {:error, {:connection_cap, _}} =
               ShareUsage.claim(terry.actor, share.id, "usr_carl", @everyone)

      # The person's cap alone, with no total.
      :ok = capped!(terry, share, 3, nil)

      assert {:ok, %{person: 3, total: 4}} =
               ShareUsage.claim(terry.actor, share.id, "usr_alice", @everyone)
    end

    test "caps set since the share was read are the ones a claim is held to; a revoked share " <>
           "and another athanor's share count nothing",
         %{terry: terry, share: share} do
      assert {:ok, %{person: 1}} = ShareUsage.claim(terry.actor, share.id, "usr_alice", @everyone)
      :ok = capped!(terry, share, 1, nil)

      assert {:error, {:connection_cap, _}} =
               ShareUsage.claim(terry.actor, share.id, "usr_alice", @everyone)

      other = owner!()

      assert {:error, :not_found} =
               ShareUsage.claim(other.actor, share.id, "usr_alice", @everyone)

      {:ok, _} = Arca.Shares.revoke(terry.actor, share.id, "needs_consent")

      assert {:error, {:share_unavailable, "revoked"}} =
               ShareUsage.claim(terry.actor, share.id, "usr_bea", @everyone)

      assert {:ok, %{people: [%{user_id: "usr_alice", count: 1}], totals: [%{count: 1}]}} =
               ShareUsage.usage(terry.actor, share.id, 1)
    end

    test "a claim under an audience the share no longer holds is refused and counts nothing; " <>
           "one under the audience it holds is counted",
         %{terry: terry, share: share} do
      group = group!([terry.user.id])
      narrowed = %{audience: "group", group_id: group.id}
      {:ok, _} = Arca.Shares.set_audience(terry.actor, share.id, @everyone, narrowed)

      assert {:error, :audience_changed} =
               ShareUsage.claim(terry.actor, share.id, "usr_alice", @everyone)

      assert {:error, :audience_changed} =
               ShareUsage.claim(terry.actor, share.id, "usr_alice", %{narrowed | group_id: "g"})

      assert {:ok, %{people: [], totals: []}} = ShareUsage.usage(terry.actor, share.id, 1)
      assert {:ok, %{person: 1}} = ShareUsage.claim(terry.actor, share.id, "usr_alice", narrowed)
    end

    test "a cap outside the rule is refused where caps are set, and an actor with no athanor " <>
           "asks nothing",
         %{share: share, terry: terry, entry: entry} do
      max = Arca.Schemas.Share.max_cap()

      for bad <- [-1, max + 1, "1", 1.5, :none] do
        assert {:error, {:invalid, _}} = Arca.Shares.set_caps(terry.actor, share.id, bad, nil)
        assert {:error, {:invalid, _}} = Arca.Shares.set_caps(terry.actor, share.id, nil, bad)

        for field <- [:person_daily, :total_daily] do
          assert {:error, {:invalid, %{^field => _}}} =
                   Arca.Shares.create(
                     terry.actor,
                     Map.put(%{entry_id: entry.id, audience: "group", group_id: "g"}, field, bad)
                   ),
                 inspect({field, bad})
        end
      end

      assert {:ok, %{person_daily: nil, total_daily: nil}} =
               Arca.Shares.get(terry.actor, share.id)

      QueryCounter.assert_queries(0, fn ->
        assert {:error, :no_athanor} =
                 ShareUsage.claim(%Prima.Actor{}, share.id, "usr_alice", @everyone)

        assert {:error, :no_athanor} = ShareUsage.usage(%Prima.Actor{}, share.id, 1)
        assert {:error, :cross_tenant} = ShareUsage.sweep(Prima.Actor.in_athanor("ath_x"))
      end)
    end
  end

  describe "used_today/3" do
    test "a person's use today is their own day row of that share, and no one else's",
         %{terry: terry, share: share} do
      other = share!(terry.actor, entry!(terry.actor).id)

      assert {:ok, 0} = ShareUsage.used_today(terry.actor, share.id, "usr_alice")

      for _ <- 1..2,
          do: {:ok, _} = ShareUsage.claim(terry.actor, share.id, "usr_alice", @everyone)

      {:ok, _} = ShareUsage.claim(terry.actor, share.id, "usr_bea", @everyone)
      {:ok, _} = ShareUsage.claim(terry.actor, other.id, "usr_alice", @everyone)

      # Alice's two on this share: not Bea's, not the share's total of
      # three, and not her use of the other share.
      assert {:ok, 2} = ShareUsage.used_today(terry.actor, share.id, "usr_alice")
      assert {:ok, 1} = ShareUsage.used_today(terry.actor, share.id, "usr_bea")
      assert {:ok, 1} = ShareUsage.used_today(terry.actor, other.id, "usr_alice")
      assert {:ok, 0} = ShareUsage.used_today(terry.actor, other.id, "usr_bea")

      # A count of an earlier day is not today's.
      {1, _} =
        Arca.Repo.insert_all(Arca.Schemas.ShareUsage, [
          %{
            athanor_id: terry.athanor.id,
            share_id: other.id,
            user_id: "usr_bea",
            day: Date.add(today(), -1),
            count: 7,
            updated_at: DateTime.utc_now()
          }
        ])

      assert {:ok, 0} = ShareUsage.used_today(terry.actor, other.id, "usr_bea")

      # The share's total is keyed by no person, and is never read as one.
      refute match?({:ok, _}, ShareUsage.used_today(terry.actor, share.id, ""))
    end
  end

  describe "sweep/1" do
    test "deletes the days past the window in every athanor, and keeps the rest",
         %{terry: terry, share: share} do
      other = owner!()
      theirs = share!(other.actor, entry!(other.actor).id)
      {:ok, _} = ShareUsage.claim(terry.actor, share.id, "usr_alice", @everyone)
      old = Date.add(today(), -(ShareUsage.kept_days() + 1))

      {1, _} =
        Arca.Repo.insert_all(Arca.Schemas.ShareUsage, [
          %{
            athanor_id: other.athanor.id,
            share_id: theirs.id,
            user_id: "usr_bea",
            day: old,
            count: 4,
            updated_at: DateTime.utc_now()
          }
        ])

      assert {:ok, 1} = ShareUsage.sweep(Prima.Actor.system())

      assert Arca.Repo.aggregate(
               from(u in Arca.Schemas.ShareUsage, where: u.share_id in ^[share.id, theirs.id]),
               :count
             ) == 2
    end
  end
end

defmodule Arca.ShareUsageRaceTest do
  @moduledoc """
  Claims on connections of their own: inside the sandbox one shared
  connection would serialize the claims the cases are about. Every row a
  case writes is removed when it ends.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.ShareUsage
  alias Arca.Test.Shares, as: Fixture
  alias Ecto.Adapters.SQL.Sandbox

  @everyone %{audience: "everyone", group_id: nil}

  # The purge is registered before the owner is made, so a case stopped at
  # its timeout leaves nothing behind.
  setup do
    {:ok, made} = Agent.start(fn -> nil end)

    on_exit(fn ->
      with %{} = owner <- Agent.get(made, & &1), do: unboxed(fn -> purge!(owner) end)
      Agent.stop(made)
    end)

    terry = unboxed(&Fixture.owner!/0)
    :ok = Agent.update(made, fn _ -> terry end)
    share = unboxed(fn -> Fixture.share!(terry.actor, Fixture.entry!(terry.actor).id) end)
    {:ok, terry: terry, share: share}
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  defp purge!(%{athanor: athanor, user: user}) do
    {:ok, _} = Arca.TenantTables.delete_all_for(Prima.Actor.in_athanor(athanor.id))
    Arca.Repo.delete_all(from(a in Arca.Schemas.Athanor, where: a.id == ^athanor.id))
    Arca.Repo.delete_all(from(i in Arca.Schemas.ExternalIdentity, where: i.user_id == ^user.id))
    Arca.Repo.delete_all(from(u in Arca.Schemas.User, where: u.id == ^user.id))
  end

  defp capped!(terry, share, person, total) do
    {:ok, _} = unboxed(fn -> Arca.Shares.set_caps(terry.actor, share.id, person, total) end)
    :ok
  end

  # One claim per person named, each on its own connection, all at once.
  defp racing(terry, share, people) do
    for person <- people do
      Task.async(fn ->
        unboxed(fn -> ShareUsage.claim(terry.actor, share.id, person, @everyone) end)
      end)
    end
    |> Task.await_many(30_000)
  end

  test "two claims for the last request of a person's day admit one",
       %{terry: terry, share: share} do
    :ok = capped!(terry, share, 1, nil)
    results = racing(terry, share, ["usr_alice", "usr_alice"])

    assert [{:error, {:connection_cap, _}}, {:ok, %{person: 1, total: 1}}] =
             Enum.sort_by(results, &match?({:ok, _}, &1))
  end

  test "two people racing for the last request of the share's day admit one",
       %{terry: terry, share: share} do
    :ok = capped!(terry, share, nil, 1)
    results = racing(terry, share, ["usr_alice", "usr_bea"])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:connection_cap, _}}, &1)) == 1

    assert {:ok, %{totals: [%{count: 1}]}} =
             unboxed(fn -> ShareUsage.usage(terry.actor, share.id, 1) end)
  end
end
