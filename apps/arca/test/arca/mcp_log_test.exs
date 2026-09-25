# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.McpLogTest do
  use ExUnit.Case, async: false

  alias Arca.McpLog

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp log_attrs(overrides) do
    Map.merge(
      %{
        id: "req_#{:rand.uniform(1_000_000)}",
        user_id: "user_1",
        athanor_id: "ath_test",
        timestamp: DateTime.utc_now(),
        status: "pending",
        tool: "execution",
        action: "run",
        method: "tools/call",
        request_id: "req_chain_1"
      },
      overrides
    )
  end

  # A row as the request log writes one: the projection of an admission
  # decision, appended with it in one transaction.
  defp seed(overrides \\ %{}) do
    attrs = log_attrs(overrides)
    actor = %{Prima.Actor.in_athanor(attrs.athanor_id) | user_id: attrs.user_id}

    decision =
      Prima.Decision.new(
        call_id: attrs.id,
        request_id: attrs.request_id,
        plane: :external,
        tool: attrs.tool,
        action: attrs.action,
        inserted_at: attrs.timestamp,
        admission: :admitted
      )

    :ok = Arca.DecisionLog.append(actor, decision, mcp_log: Map.delete(attrs, :athanor_id))
    {:ok, attrs}
  end

  describe "the projection" do
    test "a row is written with its decision, under the decision's call id" do
      {:ok, attrs} = seed()
      platform = Arca.Test.Actor.platform(user_id: "admin")

      assert %{id: id, status: "pending", tool: "execution"} =
               McpLog.get_tenant(platform, attrs.id)

      assert id == attrs.id

      assert {:ok, %{call_id: ^id}} =
               Arca.DecisionLog.get(Prima.Actor.in_athanor(attrs.athanor_id), attrs.id)
    end

    test "a row outside the status vocabulary is refused before any write" do
      assert_raise ArgumentError, ~r/invalid mcp_log/, fn -> seed(%{status: "bogus"}) end
    end
  end

  describe "list/1" do
    test "returns logs ordered by timestamp desc" do
      t1 = DateTime.add(DateTime.utc_now(), -60, :second)
      t2 = DateTime.utc_now()

      {:ok, _} = seed(log_attrs(%{id: "req_l1", timestamp: t1}))
      {:ok, _} = seed(log_attrs(%{id: "req_l2", timestamp: t2}))

      {:ok, logs} = McpLog.list(athanor_id: "ath_test")
      ids = Enum.map(logs, & &1.id)
      assert "req_l2" in ids
      assert "req_l1" in ids
      idx1 = Enum.find_index(ids, &(&1 == "req_l2"))
      idx2 = Enum.find_index(ids, &(&1 == "req_l1"))
      assert idx1 < idx2
    end

    test "filters by user_id" do
      {:ok, _} = seed(log_attrs(%{id: "req_fu1", user_id: "alice"}))
      {:ok, _} = seed(log_attrs(%{id: "req_fu2", user_id: "bob"}))

      {:ok, logs} = McpLog.list(athanor_id: "ath_test", user_id: "alice")
      assert Enum.all?(logs, &(&1.user_id == "alice"))
    end

    test "filters by status" do
      {:ok, _} = seed(log_attrs(%{id: "req_fs1", status: "success"}))
      {:ok, _} = seed(log_attrs(%{id: "req_fs2", status: "error"}))

      {:ok, logs} = McpLog.list(athanor_id: "ath_test", status: "error")
      assert logs != []
      assert Enum.all?(logs, &(&1.status == "error"))
    end

    # The chain key: an ingress request and every in-chain call beneath it
    # share one `request_id` while each row keeps its own `id`.
    test "filters by request_id, returning a whole chain" do
      {:ok, _} = seed(log_attrs(%{id: "req_root_a", request_id: "req_root_a"}))
      {:ok, _} = seed(log_attrs(%{id: "call_a1", request_id: "req_root_a"}))
      {:ok, _} = seed(log_attrs(%{id: "req_root_b", request_id: "req_root_b"}))

      {:ok, logs} = McpLog.list(athanor_id: "ath_test", request_id: "req_root_a")
      assert logs != []
      assert length(logs) == 2
      assert Enum.all?(logs, &(&1.request_id == "req_root_a"))
      assert Enum.sort(Enum.map(logs, & &1.id)) == ["call_a1", "req_root_a"]
    end

    test "filters by tool" do
      {:ok, _} = seed(log_attrs(%{id: "req_ft1", tool: "storage"}))
      {:ok, _} = seed(log_attrs(%{id: "req_ft2", tool: "execution"}))

      {:ok, logs} = McpLog.list(athanor_id: "ath_test", tool: "storage")
      assert logs != []
      assert Enum.all?(logs, &(&1.tool == "storage"))
    end

    test "filters by since" do
      old_time = DateTime.add(DateTime.utc_now(), -3600, :second)
      {:ok, _} = seed(log_attrs(%{id: "req_since1", timestamp: old_time}))
      {:ok, _} = seed(log_attrs(%{id: "req_since2", timestamp: DateTime.utc_now()}))

      cutoff = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, logs} = McpLog.list(athanor_id: "ath_test", since: cutoff)
      ids = Enum.map(logs, & &1.id)
      assert "req_since2" in ids
      refute "req_since1" in ids
    end

    test "respects limit" do
      for i <- 1..5 do
        {:ok, _} = seed(log_attrs(%{id: "req_lim_#{i}"}))
      end

      {:ok, logs} = McpLog.list(athanor_id: "ath_test", limit: 2)
      assert length(logs) <= 2
    end
  end

  describe "get_tenant/2" do
    test "platform scope returns log without tenant filtering" do
      {:ok, log} =
        seed(log_attrs(%{id: "req_plat", athanor_id: "ath_x"}))

      platform = Arca.Test.Actor.platform(user_id: "admin")

      assert %{id: "req_plat"} = McpLog.get_tenant(platform, log.id)
    end

    test "athanor scope filters by tenant" do
      {:ok, _} = seed(log_attrs(%{id: "req_t1", athanor_id: "ath_a"}))

      match = %Prima.Actor{
        athanor_id: "ath_a",
        user_id: "u",
        authenticated: true,
        scope: :athanor,
        system: false
      }

      miss = %{match | athanor_id: "ath_b"}

      assert %{id: _} = McpLog.get_tenant(match, "req_t1")
      assert is_nil(McpLog.get_tenant(miss, "req_t1"))
    end
  end

  describe "delete_before/2" do
    test "deletes logs before cutoff scoped by tenant" do
      old_time = DateTime.add(DateTime.utc_now(), -7200, :second)
      {:ok, _} = seed(log_attrs(%{id: "req_del1", timestamp: old_time}))
      {:ok, _} = seed(log_attrs(%{id: "req_del2", timestamp: DateTime.utc_now()}))

      cutoff = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, count} = McpLog.delete_before(cutoff, athanor_id: "ath_test")
      assert count >= 1

      platform = Arca.Test.Actor.platform(user_id: "admin")

      assert is_nil(McpLog.get_tenant(platform, "req_del1"))
      assert %{id: _} = McpLog.get_tenant(platform, "req_del2")
    end

    test "respects tenant scoping" do
      old_time = DateTime.add(DateTime.utc_now(), -7200, :second)

      {:ok, _} =
        seed(
          log_attrs(%{
            id: "req_delt1",
            timestamp: old_time,
            athanor_id: "ath_a"
          })
        )

      {:ok, _} =
        seed(
          log_attrs(%{
            id: "req_delt2",
            timestamp: old_time,
            athanor_id: "ath_b"
          })
        )

      cutoff = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, count} = McpLog.delete_before(cutoff, athanor_id: "ath_a")
      assert count >= 1

      platform = Arca.Test.Actor.platform(user_id: "admin")

      # ath_a record deleted
      assert is_nil(McpLog.get_tenant(platform, "req_delt1"))
      # ath_b record untouched
      assert %{id: _} = McpLog.get_tenant(platform, "req_delt2")
    end
  end

  describe "stats/1" do
    test "returns aggregated stats" do
      {:ok, _} = seed(log_attrs(%{id: "req_st1", status: "success", duration_ms: 100}))
      {:ok, _} = seed(log_attrs(%{id: "req_st2", status: "success", duration_ms: 200}))
      {:ok, _} = seed(log_attrs(%{id: "req_st3", status: "error", duration_ms: 50}))

      {:ok, stats} = McpLog.stats(athanor_id: "ath_test")
      assert stats.total >= 3
      assert stats.errors >= 1
      assert is_integer(stats.avg_duration_ms)
    end

    test "filters by since" do
      old_time = DateTime.add(DateTime.utc_now(), -7200, :second)

      {:ok, _} =
        seed(log_attrs(%{id: "req_sts1", timestamp: old_time, status: "success"}))

      {:ok, _} =
        seed(
          log_attrs(%{id: "req_sts2", timestamp: DateTime.utc_now(), status: "success"})
        )

      cutoff = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, stats} = McpLog.stats(athanor_id: "ath_test", since: cutoff)
      # Only recent log should be counted
      assert stats.total >= 1
    end
  end

  describe "tenant isolation" do
    test "list/1 only returns logs from the specified tenant" do
      actor_a = Arca.Test.Actor.local(athanor_id: "ath_a", user_id: "user_a")
      actor_b = Arca.Test.Actor.local(athanor_id: "ath_b", user_id: "user_b")

      {:ok, _} =
        seed(log_attrs(%{id: "req_iso_a", athanor_id: actor_a.athanor_id}))

      {:ok, _} =
        seed(log_attrs(%{id: "req_iso_b", athanor_id: actor_b.athanor_id}))

      {:ok, logs_a} = McpLog.list(athanor_id: actor_a.athanor_id)
      {:ok, logs_b} = McpLog.list(athanor_id: actor_b.athanor_id)

      ids_a = Enum.map(logs_a, & &1.id)
      ids_b = Enum.map(logs_b, & &1.id)

      assert "req_iso_a" in ids_a
      refute "req_iso_b" in ids_a
      assert "req_iso_b" in ids_b
      refute "req_iso_a" in ids_b
    end

    test "stats/1 respects tenant boundaries" do
      actor_a = Arca.Test.Actor.local(athanor_id: "ath_a", user_id: "user_a")
      actor_b = Arca.Test.Actor.local(athanor_id: "ath_b", user_id: "user_b")

      {:ok, _} =
        seed(
          log_attrs(%{
            id: "req_iso_s1",
            athanor_id: actor_a.athanor_id,
            status: "error"
          })
        )

      {:ok, _} =
        seed(
          log_attrs(%{
            id: "req_iso_s2",
            athanor_id: actor_b.athanor_id,
            status: "success"
          })
        )

      {:ok, stats_a} = McpLog.stats(athanor_id: actor_a.athanor_id)
      {:ok, stats_b} = McpLog.stats(athanor_id: actor_b.athanor_id)

      assert stats_a.errors >= 1
      assert stats_b.errors == 0
    end
  end
end
