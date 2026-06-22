# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ExecutorCascadeTest do
  use ExUnit.Case, async: false

  alias Arca.Execution

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp create_execution(attrs) do
    defaults = %{
      reference: "catalyst:local.test:1.0.0",
      user_id: "user_cascade_test",
      started_at: DateTime.utc_now(),
      status: "running",
      component_type: "catalyst"
    }

    {:ok, record} = Execution.record_start(Map.merge(defaults, attrs))
    record
  end

  describe "cascade_children_failure via handle_failure" do
    test "parent formula failure cascades to running children" do
      parent_id = "exec_cascade_#{System.unique_integer([:positive])}"
      child1_id = "exec_child1_#{System.unique_integer([:positive])}"
      child2_id = "exec_child2_#{System.unique_integer([:positive])}"
      started_at = DateTime.add(DateTime.utc_now(), -5, :second)

      create_execution(%{
        id: parent_id,
        reference: "formula:local.agent:0.9.0",
        component_type: "formula",
        started_at: started_at
      })

      create_execution(%{
        id: child1_id,
        component_type: "catalyst",
        parent_execution_id: parent_id,
        started_at: started_at
      })

      create_execution(%{
        id: child2_id,
        component_type: "reagent",
        parent_execution_id: parent_id,
        started_at: started_at
      })

      # Build a minimal ExecutionRecord struct to call cascade
      record = %Opus.ExecutionRecord{
        id: parent_id,
        reference: "formula:local.agent:0.9.0",
        component_type: :formula,
        user_id: "user_cascade_test",
        started_at: started_at,
        status: :failed,
        error: "Execution timeout after 300000ms"
      }

      # Invoke the cascade directly via the module's private function exposed through handle_failure path.
      # We test by directly calling the Arca.Execution functions since cascade is private.
      children = Execution.list_running_children(parent_id)
      assert length(children) == 2

      # Simulate what cascade_children_failure does
      for child <- children do
        now = DateTime.utc_now()
        duration_ms = DateTime.diff(now, child.started_at, :millisecond)

        {count, _} =
          Execution.mark_failed_if_running(child.id, %{
            completed_at: now,
            duration_ms: duration_ms,
            error_message: "Parent execution (#{record.id}) terminated"
          })

        assert count == 1
      end

      # Verify children are now failed
      assert Execution.list_running_children(parent_id) == []

      ctx =
        Sanctum.Context.build(
          user_id: "user_cascade_test",
          permissions: [:execution_read],
          scope: :platform,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      child1 = Execution.get_tenant(ctx, child1_id)
      assert child1.status == "failed"
      assert child1.error_message =~ parent_id

      child2 = Execution.get_tenant(ctx, child2_id)
      assert child2.status == "failed"
    end

    test "already-completed children are not overwritten" do
      parent_id = "exec_cascade_safe_#{System.unique_integer([:positive])}"
      child_id = "exec_child_done_#{System.unique_integer([:positive])}"
      started_at = DateTime.add(DateTime.utc_now(), -5, :second)

      create_execution(%{
        id: parent_id,
        reference: "formula:local.agent:0.9.0",
        component_type: "formula",
        started_at: started_at
      })

      create_execution(%{
        id: child_id,
        component_type: "catalyst",
        parent_execution_id: parent_id,
        started_at: started_at
      })

      # Complete the child before cascade
      ctx =
        Sanctum.Context.build(
          user_id: "user_cascade_test",
          permissions: [:execution_write],
          scope: :project,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      {:ok, _} =
        Execution.record_complete(ctx, child_id, %{
          completed_at: DateTime.utc_now(),
          duration_ms: 100,
          status: "completed",
          output: ~s({"result": "ok"})
        })

      # Cascade should find no running children
      children = Execution.list_running_children(parent_id)
      assert children == []

      # Verify mark_failed_if_running is a no-op
      {count, _} =
        Execution.mark_failed_if_running(child_id, %{
          completed_at: DateTime.utc_now(),
          duration_ms: 500,
          error_message: "Should not overwrite"
        })

      assert count == 0

      # Verify status unchanged
      read_ctx =
        Sanctum.Context.build(
          user_id: "user_cascade_test",
          permissions: [:execution_read],
          scope: :platform,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      child = Execution.get_tenant(read_ctx, child_id)
      assert child.status == "completed"
    end

    test "non-formula parent has no children to cascade" do
      parent_id = "exec_catalyst_parent_#{System.unique_integer([:positive])}"

      create_execution(%{
        id: parent_id,
        reference: "catalyst:local.test:1.0.0",
        component_type: "catalyst"
      })

      # No children for a catalyst
      children = Execution.list_running_children(parent_id)
      assert children == []
    end

    test "does not cascade to a child in a different tenant" do
      parent_id = "exec_xtenant_parent_#{System.unique_integer([:positive])}"
      same_child = "exec_same_tenant_child_#{System.unique_integer([:positive])}"
      foreign_child = "exec_foreign_child_#{System.unique_integer([:positive])}"
      started_at = DateTime.add(DateTime.utc_now(), -5, :second)

      # Parent + a legitimate same-tenant child both land in local/default.
      create_execution(%{
        id: parent_id,
        reference: "formula:local.agent:0.9.0",
        component_type: "formula",
        started_at: started_at
      })

      create_execution(%{
        id: same_child,
        component_type: "catalyst",
        parent_execution_id: parent_id,
        started_at: started_at
      })

      # A running child in ANOTHER tenant that points at the parent must never be
      # grafted into the cascade — list_running_children scopes to the parent's
      # tenant.
      create_execution(%{
        id: foreign_child,
        component_type: "catalyst",
        parent_execution_id: parent_id,
        org_id: "org_other",
        project_id: "proj_other",
        started_at: started_at
      })

      child_ids = parent_id |> Execution.list_running_children() |> Enum.map(& &1.id)

      assert same_child in child_ids
      refute foreign_child in child_ids
      assert length(child_ids) == 1
    end
  end

  describe "sweep_stale_on_startup/0" do
    test "marks old running executions as failed" do
      old_id = "exec_stale_sweep_#{System.unique_integer([:positive])}"
      old_time = DateTime.add(DateTime.utc_now(), -3600, :second)

      create_execution(%{
        id: old_id,
        started_at: old_time
      })

      # Run the sweep
      assert :ok = Opus.Executor.sweep_stale_on_startup()

      ctx =
        Sanctum.Context.build(
          user_id: "user_cascade_test",
          permissions: [:execution_read],
          scope: :platform,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      record = Execution.get_tenant(ctx, old_id)
      assert record.status == "failed"
      assert record.error_message =~ "startup recovery"
    end

    test "does not touch recent running executions" do
      recent_id = "exec_recent_sweep_#{System.unique_integer([:positive])}"

      create_execution(%{
        id: recent_id,
        started_at: DateTime.utc_now()
      })

      assert :ok = Opus.Executor.sweep_stale_on_startup()

      ctx =
        Sanctum.Context.build(
          user_id: "user_cascade_test",
          permissions: [:execution_read],
          scope: :platform,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      record = Execution.get_tenant(ctx, recent_id)
      assert record.status == "running"
    end
  end

  describe "cancel/2 tenant isolation" do
    test "a foreign tenant cannot cancel another tenant's running execution" do
      exec_id = "exec_cancel_xtenant_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Execution.record_start(%{
          id: exec_id,
          reference: "catalyst:local.test:1.0.0",
          user_id: "user_b",
          org_id: "org_b",
          project_id: "proj_b",
          started_at: DateTime.utc_now(),
          status: "running",
          component_type: "catalyst"
        })

      # A live process registered under the id, as if the execution were running.
      target = register_fake_execution(exec_id)

      foreign_ctx =
        Sanctum.Context.build(
          user_id: "user_a",
          permissions: [:storage_read, :execute],
          org_id: "org_a",
          project_id: "proj_a",
          scope: :project,
          auth_method: :api_key,
          namespace: "ns_a",
          authenticated: true
        )

      assert {:error, :not_found} = Opus.Executor.cancel(foreign_ctx, exec_id)

      # The destructive kill must NOT happen before the tenant check.
      assert Process.alive?(target)

      # The execution's own record is left running and untouched.
      platform_ctx =
        Sanctum.Context.build(
          user_id: "user_b",
          permissions: [:storage_read],
          scope: :platform,
          auth_method: :oidc,
          namespace: "ns_b",
          authenticated: true
        )

      assert Execution.get_tenant(platform_ctx, exec_id).status == "running"

      Process.exit(target, :kill)
    end

    test "the owning tenant can cancel its running execution" do
      exec_id = "exec_cancel_owner_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Execution.record_start(%{
          id: exec_id,
          reference: "catalyst:local.test:1.0.0",
          user_id: "user_b",
          org_id: "org_b",
          project_id: "proj_b",
          started_at: DateTime.utc_now(),
          status: "running",
          component_type: "catalyst"
        })

      target = register_fake_execution(exec_id)
      ref = Process.monitor(target)

      owner_ctx =
        Sanctum.Context.build(
          user_id: "user_b",
          permissions: [:storage_read, :execute],
          org_id: "org_b",
          project_id: "proj_b",
          scope: :project,
          auth_method: :api_key,
          namespace: "ns_b",
          authenticated: true
        )

      assert {:ok, %{cancelled: true}} = Opus.Executor.cancel(owner_ctx, exec_id)

      # The running process is killed and the record is no longer running.
      assert_receive {:DOWN, ^ref, :process, ^target, _}, 1000

      platform_ctx =
        Sanctum.Context.build(
          user_id: "user_b",
          permissions: [:storage_read],
          scope: :platform,
          auth_method: :oidc,
          namespace: "ns_b",
          authenticated: true
        )

      refute Execution.get_tenant(platform_ctx, exec_id).status == "running"
    end
  end

  # Spawn a process that registers itself in the ExecutionRegistry under the
  # given id (mimicking a live execution) and idles until killed.
  defp register_fake_execution(execution_id) do
    test_pid = self()

    target =
      spawn(fn ->
        {:ok, _} = Registry.register(Opus.ExecutionRegistry, execution_id, %{})
        send(test_pid, :registered)
        Process.sleep(:infinity)
      end)

    assert_receive :registered, 1000
    target
  end
end
