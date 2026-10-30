# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ShareUsageTest do
  use ExUnit.Case, async: false

  import Arca.Test.Shares
  import Ecto.Query

  alias Arca.ShareUsage
  alias Arca.Test.QueryCounter

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

  describe "claim/3" do
    test "an absent cap is no limit, and every use is counted", %{terry: terry, share: share} do
      for n <- 1..3 do
        assert {:ok, %{person: ^n, total: ^n, day: day}} =
                 ShareUsage.claim(terry.actor, share.id, "usr_alice")

        assert day == today()
      end

      assert {:ok, %{people: [%{user_id: "usr_alice", count: 3}], totals: [%{count: 3}]}} =
               ShareUsage.usage(terry.actor, share.id, 1)
    end

    test "0 admits no use and counts none", %{terry: terry, share: share} do
      :ok = capped!(terry, share, 0, nil)

      assert {:error, {:connection_cap, reset_at}} =
               ShareUsage.claim(terry.actor, share.id, "usr_alice")

      assert reset_at == DateTime.new!(Date.add(today(), 1), ~T[00:00:00.000000], "Etc/UTC")
      assert {:ok, %{people: [], totals: []}} = ShareUsage.usage(terry.actor, share.id, 1)

      :ok = capped!(terry, share, nil, 0)

      assert {:error, {:connection_cap, _}} =
               ShareUsage.claim(terry.actor, share.id, "usr_bea")
    end

    test "N admits N a person and N in total that day, each cap on its own",
         %{terry: terry, share: share} do
      :ok = capped!(terry, share, 2, 3)

      assert {:ok, %{person: 1}} = ShareUsage.claim(terry.actor, share.id, "usr_alice")
      assert {:ok, %{person: 2}} = ShareUsage.claim(terry.actor, share.id, "usr_alice")

      assert {:error, {:connection_cap, _}} =
               ShareUsage.claim(terry.actor, share.id, "usr_alice")

      assert {:ok, %{person: 1, total: 3}} =
               ShareUsage.claim(terry.actor, share.id, "usr_bea")

      assert {:error, {:connection_cap, _}} =
               ShareUsage.claim(terry.actor, share.id, "usr_carl")

      # The person's cap alone, with no total.
      :ok = capped!(terry, share, 3, nil)

      assert {:ok, %{person: 3, total: 4}} =
               ShareUsage.claim(terry.actor, share.id, "usr_alice")
    end

    test "caps set since the share was read are the ones a claim is held to; a revoked share " <>
           "and another athanor's share count nothing",
         %{terry: terry, share: share} do
      assert {:ok, %{person: 1}} = ShareUsage.claim(terry.actor, share.id, "usr_alice")
      :ok = capped!(terry, share, 1, nil)

      assert {:error, {:connection_cap, _}} =
               ShareUsage.claim(terry.actor, share.id, "usr_alice")

      other = owner!()
      assert {:error, :not_found} = ShareUsage.claim(other.actor, share.id, "usr_alice")

      {:ok, _} = Arca.Shares.revoke(terry.actor, share.id, "needs_consent")

      assert {:error, {:share_unavailable, "revoked"}} =
               ShareUsage.claim(terry.actor, share.id, "usr_bea")

      assert {:ok, %{people: [%{user_id: "usr_alice", count: 1}], totals: [%{count: 1}]}} =
               ShareUsage.usage(terry.actor, share.id, 1)
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
        assert {:error, :no_athanor} = ShareUsage.claim(%Prima.Actor{}, share.id, "usr_alice")
        assert {:error, :no_athanor} = ShareUsage.usage(%Prima.Actor{}, share.id, 1)
        assert {:error, :cross_tenant} = ShareUsage.sweep(Prima.Actor.in_athanor("ath_x"))
      end)
    end
  end

  describe "sweep/1" do
    test "deletes the days past the window in every athanor, and keeps the rest",
         %{terry: terry, share: share} do
      other = owner!()
      theirs = share!(other.actor, entry!(other.actor).id)
      {:ok, _} = ShareUsage.claim(terry.actor, share.id, "usr_alice")
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
