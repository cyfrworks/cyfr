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
    {:ok, terry: terry, share: share!(terry.actor, entry!(terry.actor).id)}
  end

  defp caps(person, total), do: %{person_daily: person, total_daily: total}

  defp capped!(terry, share, person, total) do
    {:ok, _} = Arca.Shares.set_caps(terry.actor, share.id, person, total)
    caps(person, total)
  end

  defp today, do: DateTime.to_date(Arca.ServerMetaStorage.now!())

  describe "claim/4" do
    test "an absent cap is no limit, and every use is counted", %{terry: terry, share: share} do
      for n <- 1..3 do
        assert {:ok, %{person: ^n, total: ^n, day: day}} =
                 ShareUsage.claim(terry.actor, share.id, "usr_alice", caps(nil, nil))

        assert day == today()
      end

      assert {:ok, %{people: [%{user_id: "usr_alice", count: 3}], totals: [%{count: 3}]}} =
               ShareUsage.usage(terry.actor, share.id, 1)
    end

    test "0 admits no use and counts none", %{terry: terry, share: share} do
      caps = capped!(terry, share, 0, nil)

      assert {:error, {:connection_cap, reset_at}} =
               ShareUsage.claim(terry.actor, share.id, "usr_alice", caps)

      assert reset_at == DateTime.new!(Date.add(today(), 1), ~T[00:00:00.000000], "Etc/UTC")
      assert {:ok, %{people: [], totals: []}} = ShareUsage.usage(terry.actor, share.id, 1)

      caps = capped!(terry, share, nil, 0)

      assert {:error, {:connection_cap, _}} =
               ShareUsage.claim(terry.actor, share.id, "usr_bea", caps)
    end

    test "N admits N a person and N in total that day, each cap on its own",
         %{terry: terry, share: share} do
      caps = capped!(terry, share, 2, 3)

      assert {:ok, %{person: 1}} = ShareUsage.claim(terry.actor, share.id, "usr_alice", caps)
      assert {:ok, %{person: 2}} = ShareUsage.claim(terry.actor, share.id, "usr_alice", caps)

      assert {:error, {:connection_cap, _}} =
               ShareUsage.claim(terry.actor, share.id, "usr_alice", caps)

      assert {:ok, %{person: 1, total: 3}} =
               ShareUsage.claim(terry.actor, share.id, "usr_bea", caps)

      assert {:error, {:connection_cap, _}} =
               ShareUsage.claim(terry.actor, share.id, "usr_carl", caps)

      # The person's cap alone, with no total.
      caps = capped!(terry, share, 3, nil)

      assert {:ok, %{person: 3, total: 4}} =
               ShareUsage.claim(terry.actor, share.id, "usr_alice", caps)
    end

    test "a revoked share, caps it no longer holds and another athanor's share count nothing",
         %{terry: terry, share: share} do
      assert {:error, :caps_moved} =
               ShareUsage.claim(terry.actor, share.id, "usr_alice", caps(5, nil))

      other = owner!()

      assert {:error, :not_found} =
               ShareUsage.claim(other.actor, share.id, "usr_alice", caps(nil, nil))

      {:ok, _} = Arca.Shares.revoke(terry.actor, share.id, "needs_consent")

      assert {:error, {:share_unavailable, "revoked"}} =
               ShareUsage.claim(terry.actor, share.id, "usr_alice", caps(nil, nil))

      assert {:ok, %{people: [], totals: []}} = ShareUsage.usage(terry.actor, share.id, 1)
    end

    test "a cap outside the share's rules, and an actor with no athanor, ask nothing",
         %{share: share, terry: terry} do
      QueryCounter.assert_queries(0, fn ->
        for caps <- [caps(-1, nil), caps(nil, Arca.Schemas.Share.max_cap() + 1), caps("1", nil)] do
          assert {:error, {:invalid, _}} =
                   ShareUsage.claim(terry.actor, share.id, "usr_alice", caps)
        end

        assert {:error, :no_athanor} =
                 ShareUsage.claim(%Prima.Actor{}, share.id, "usr_alice", caps(nil, nil))

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
      {:ok, _} = ShareUsage.claim(terry.actor, share.id, "usr_alice", caps(nil, nil))
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
