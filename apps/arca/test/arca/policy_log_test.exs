# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PolicyLogTest do
  use ExUnit.Case, async: false

  alias Arca.PolicyLog

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp log_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        id: "pl_#{:rand.uniform(1_000_000)}",
        user_id: "user_1",
        athanor_id: "ath_test",
        timestamp: DateTime.utc_now(),
        event_type: "policy_consultation",
        component_ref: "math:1.0.0",
        component_type: "formula",
        decision: "allowed",
        decision_reason: "default policy"
      },
      overrides
    )
  end

  describe "record/1" do
    test "inserts a valid policy log" do
      attrs = log_attrs()
      assert {:ok, log} = PolicyLog.record(attrs)
      assert log.id == attrs.id
      assert log.user_id == "user_1"
      assert log.event_type == "policy_consultation"
      assert log.decision == "allowed"
    end

    test "rejects missing required fields" do
      assert {:error, {:invalid, errors}} = PolicyLog.record(%{})
      assert errors != %{}
    end
  end

  describe "list/1" do
    test "returns logs ordered by timestamp desc" do
      t1 = DateTime.add(DateTime.utc_now(), -60, :second)
      t2 = DateTime.utc_now()

      {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_list_1", timestamp: t1}))
      {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_list_2", timestamp: t2}))

      {:ok, logs} = PolicyLog.list(athanor_id: "ath_test")
      ids = Enum.map(logs, & &1.id)
      assert "pl_list_2" in ids
      assert "pl_list_1" in ids
      # Most recent first
      idx1 = Enum.find_index(ids, &(&1 == "pl_list_2"))
      idx2 = Enum.find_index(ids, &(&1 == "pl_list_1"))
      assert idx1 < idx2
    end

    test "filters by user_id" do
      {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_u1", user_id: "alice"}))
      {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_u2", user_id: "bob"}))

      {:ok, logs} = PolicyLog.list(athanor_id: "ath_test", user_id: "alice")
      assert Enum.all?(logs, &(&1.user_id == "alice"))
    end

    test "filters by request_id" do
      {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_r1", request_id: "req_123"}))
      {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_r2", request_id: "req_456"}))

      {:ok, logs} = PolicyLog.list(athanor_id: "ath_test", request_id: "req_123")
      assert logs != []
      assert Enum.all?(logs, &(&1.request_id == "req_123"))
    end

    test "filters by execution_id" do
      {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_e1", execution_id: "exec_1"}))
      {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_e2", execution_id: "exec_2"}))

      {:ok, logs} = PolicyLog.list(athanor_id: "ath_test", execution_id: "exec_1")
      assert logs != []
      assert Enum.all?(logs, &(&1.execution_id == "exec_1"))
    end

    test "filters by event_type" do
      {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_et1", event_type: "denied"}))
      {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_et2", event_type: "violation"}))

      {:ok, logs} = PolicyLog.list(athanor_id: "ath_test", event_type: "denied")
      assert logs != []
      assert Enum.all?(logs, &(&1.event_type == "denied"))
    end

    test "respects limit" do
      for i <- 1..5 do
        {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_lim_#{i}"}))
      end

      {:ok, logs} = PolicyLog.list(athanor_id: "ath_test", limit: 2)
      assert length(logs) <= 2
    end
  end

  describe "get_tenant/2" do
    test "platform scope returns log without tenant filtering" do
      {:ok, log} =
        PolicyLog.record(log_attrs(%{id: "pl_plat", athanor_id: "ath_x"}))

      platform_actor = Arca.Test.Actor.platform(user_id: "admin")

      assert %{id: "pl_plat"} = PolicyLog.get_tenant(platform_actor, log.id)
    end

    test "athanor scope filters by tenant" do
      {:ok, _} =
        PolicyLog.record(log_attrs(%{id: "pl_t1", athanor_id: "ath_a"}))

      actor_match = %Cyfr.Actor{
        user_id: "u",
        athanor_id: "ath_a",
        authenticated: true,
        scope: :athanor,
        system: false
      }

      actor_miss = %{actor_match | athanor_id: "ath_b"}

      assert %{id: _} = PolicyLog.get_tenant(actor_match, "pl_t1")
      assert is_nil(PolicyLog.get_tenant(actor_miss, "pl_t1"))
    end
  end

  describe "get_by_request_id_tenant/2" do
    test "platform scope returns log by request_id" do
      {:ok, _} = PolicyLog.record(log_attrs(%{id: "pl_br1", request_id: "req_plat"}))

      platform_actor = Arca.Test.Actor.platform(user_id: "admin")

      assert %{request_id: "req_plat"} =
               PolicyLog.get_by_request_id_tenant(platform_actor, "req_plat")
    end

    test "athanor scope filters by tenant" do
      {:ok, _} =
        PolicyLog.record(
          log_attrs(%{
            id: "pl_br2",
            request_id: "req_scoped",
            athanor_id: "ath_a"
          })
        )

      actor_match = %Cyfr.Actor{
        user_id: "u",
        athanor_id: "ath_a",
        authenticated: true,
        scope: :athanor,
        system: false
      }

      actor_miss = %{actor_match | athanor_id: "ath_b"}

      assert %{id: _} = PolicyLog.get_by_request_id_tenant(actor_match, "req_scoped")
      assert is_nil(PolicyLog.get_by_request_id_tenant(actor_miss, "req_scoped"))
    end
  end

  describe "tenant isolation" do
    test "list/1 only returns logs from the specified tenant" do
      actor_a = Arca.Test.Actor.local(athanor_id: "ath_a", user_id: "user_a")
      actor_b = Arca.Test.Actor.local(athanor_id: "ath_b", user_id: "user_b")

      {:ok, _} =
        PolicyLog.record(log_attrs(%{id: "pl_iso_a", athanor_id: actor_a.athanor_id}))

      {:ok, _} =
        PolicyLog.record(log_attrs(%{id: "pl_iso_b", athanor_id: actor_b.athanor_id}))

      {:ok, logs_a} = PolicyLog.list(athanor_id: actor_a.athanor_id)
      {:ok, logs_b} = PolicyLog.list(athanor_id: actor_b.athanor_id)

      ids_a = Enum.map(logs_a, & &1.id)
      ids_b = Enum.map(logs_b, & &1.id)

      assert "pl_iso_a" in ids_a
      refute "pl_iso_b" in ids_a
      assert "pl_iso_b" in ids_b
      refute "pl_iso_a" in ids_b
    end
  end
end
