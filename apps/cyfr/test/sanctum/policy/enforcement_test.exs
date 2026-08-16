# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Policy.EnforcementTest do
  use ExUnit.Case, async: false

  alias Sanctum.Policy.Enforcement

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp rows_for(ctx, component_ref) do
    [athanor_id: ctx.athanor_id, limit: 50]
    |> Arca.PolicyLog.list()
    |> Enum.filter(&(&1.component_ref == component_ref))
  end

  describe "record/1" do
    test "persists a denied decision as a policy log row", %{ctx: ctx} do
      assert :ok =
               Enforcement.record(%{
                 ctx: ctx,
                 component_ref: "catalyst:local.demo",
                 component_type: :catalyst,
                 event_type: :domain_blocked,
                 decision: :denied,
                 decision_reason: "domain evil.com not in allowed_domains"
               })

      assert [row] = rows_for(ctx, "catalyst:local.demo")
      assert row.event_type == "domain_blocked"
      assert row.decision == "denied"
      assert row.component_type == "catalyst"
      assert row.decision_reason =~ "evil.com"
      assert String.starts_with?(row.id, "polog")
    end

    test "encodes host_policy_snapshot and emits decision telemetry", %{ctx: ctx} do
      handler = "enforcement-test-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:cyfr, :sanctum, :policy, :decision],
        fn _event, meas, meta, _ -> send(parent, {:decision, meas, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert :ok =
               Enforcement.record(%{
                 ctx: ctx,
                 component_ref: "catalyst:local.snap",
                 event_type: :policy_consultation,
                 decision: :allowed,
                 execution_id: "exec_test123",
                 host_policy_snapshot: %{allowed_domains: ["api.example.com"]}
               })

      assert_received {:decision, %{system_time: _},
                       %{event_type: "policy_consultation", decision: "allowed"}}

      assert [row] = rows_for(ctx, "catalyst:local.snap")
      assert row.execution_id == "exec_test123"
      assert row.host_policy_snapshot =~ "api.example.com"
    end

    test "missing ctx is swallowed and inserts nothing", %{ctx: ctx} do
      assert :ok =
               Enforcement.record(%{component_ref: "catalyst:local.noctx", event_type: :denied})

      assert rows_for(ctx, "catalyst:local.noctx") == []
    end
  end

  describe "retention" do
    test "cleanup_policy_logs deletes rows older than policy_log_days", %{ctx: ctx} do
      assert :ok =
               Enforcement.record(%{
                 ctx: ctx,
                 component_ref: "catalyst:local.old",
                 event_type: :rate_limit,
                 decision: :denied
               })

      # Backdate the row past the retention window.
      old_ts = DateTime.utc_now() |> DateTime.add(-90 * 86_400, :second)

      [row] = rows_for(ctx, "catalyst:local.old")

      import Ecto.Query

      Arca.Repo.update_all(
        from(l in Arca.PolicyLog, where: l.id == ^row.id),
        set: [timestamp: old_ts]
      )

      assert {:ok, %{would_delete: 1}} = Arca.Retention.cleanup_policy_logs(ctx, dry_run: true)
      assert {:ok, 1} = Arca.Retention.cleanup_policy_logs(ctx)
      assert rows_for(ctx, "catalyst:local.old") == []
    end
  end
end
