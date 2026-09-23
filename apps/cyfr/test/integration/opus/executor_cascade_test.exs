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
      athanor_id: Sanctum.TestContext.athanor_id(),
      started_at: DateTime.utc_now(),
      status: "running",
      component_type: "catalyst"
    }

    {:ok, record} = Execution.record_start(Map.merge(defaults, attrs))
    record
  end

  describe "Cyfr.Execution.Cascade.fail_children/1" do
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

      record = %Cyfr.Execution.Record{
        id: parent_id,
        reference: "formula:local.agent:0.9.0",
        component_type: :formula,
        user_id: "user_cascade_test",
        started_at: started_at,
        status: :failed,
        error: "Execution timeout after 300000ms"
      }

      assert length(Execution.list_running_children(parent_id)) == 2
      assert :ok = Cyfr.Execution.Cascade.fail_children(record)

      # Verify children are now failed
      assert Execution.list_running_children(parent_id) == []

      ctx =
        Sanctum.TestContext.platform(
          user_id: "user_cascade_test",
          permissions: [:execution_read],
          auth_method: :oidc,
          namespace: "testns"
        )

      child1 = Execution.get_tenant(Sanctum.Context.actor(ctx), child1_id)
      assert child1.status == "failed"
      assert child1.error_message =~ parent_id

      child2 = Execution.get_tenant(Sanctum.Context.actor(ctx), child2_id)
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
          athanor_id: Sanctum.TestContext.athanor_id(),
          permissions: [],
          scope: :athanor,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      {:ok, _} =
        Execution.record_complete(
          Sanctum.Context.actor(ctx),
          child_id,
          %{
            completed_at: DateTime.utc_now(),
            duration_ms: 100,
            status: "completed",
            output: ~s({"result": "ok"})
          },
          Cyfr.Test.AttemptFixtures.standing(Sanctum.TestContext.athanor_id())
        )

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
        Sanctum.TestContext.platform(
          user_id: "user_cascade_test",
          permissions: [:execution_read],
          auth_method: :oidc,
          namespace: "testns"
        )

      child = Execution.get_tenant(Sanctum.Context.actor(read_ctx), child_id)
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

      # Parent + a legitimate same-tenant child both land in the same athanor.
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
        athanor_id: "ath_other",
        started_at: started_at
      })

      child_ids = parent_id |> Execution.list_running_children() |> Enum.map(& &1.id)

      assert same_child in child_ids
      refute foreign_child in child_ids
      assert length(child_ids) == 1
    end
  end

  describe "a normal completion is not a cascade" do
    test "only the abnormal endings cascade" do
      # Successful parents leave asynchronous children running. Failure and
      # cancellation cascade; abandoned children are reaped by lease expiry.
      read = fn path -> [__DIR__, path] |> Path.join() |> Path.expand() |> File.read!() end
      dispatch = read.("../../../lib/cyfr/execution/dispatch.ex")
      lapse = read.("../../../lib/cyfr/execution/lapse.ex")
      close = read.("../../../lib/cyfr/execution/close.ex")

      callers =
        Enum.join([dispatch, lapse, close], "\n")
        |> String.split("\n")
        |> Enum.filter(&(String.trim(&1) =~ ~r/^Cascade\.fail_children(_of)?\(/))
        |> Enum.map(&String.trim/1)

      assert length(callers) == 3,
             "expected exactly the failure, cancel and lapse cascades, got: #{inspect(callers)}"

      # ...and the success path returns without one.
      [_before, complete] = String.split(close, "def complete(", parts: 2)
      [complete_body | _] = String.split(complete, ~r/\n  (@doc|def |defp )/, parts: 2)
      refute complete_body =~ "Cascade."
    end

    test "a completed parent leaves a running child alone" do
      parent_id = "exec_ok_parent_#{System.unique_integer([:positive])}"
      child_id = "exec_ok_child_#{System.unique_integer([:positive])}"
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

      # The parent finishes normally.
      {:ok, _} =
        Execution.record_complete(
          Sanctum.Context.actor(Sanctum.TestContext.local()),
          parent_id,
          %{
            status: "completed",
            completed_at: DateTime.utc_now(),
            duration_ms: 5_000,
            output: ~s({"ok":true})
          },
          Cyfr.Test.AttemptFixtures.standing(Sanctum.TestContext.athanor_id())
        )

      # Nothing swept the child with it; it is still the streaming child's own
      # to finish.
      assert [%{id: ^child_id, status: "running"}] = Execution.list_running_children(parent_id)
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
          athanor_id: "ath_b",
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
          athanor_id: "ath_a",
          scope: :athanor,
          auth_method: :api_key,
          namespace: "ns_a",
          authenticated: true
        )

      assert {:error, :not_found} = Cyfr.Execution.Dispatch.cancel(foreign_ctx, exec_id)

      # The destructive kill must NOT happen before the tenant check.
      assert Process.alive?(target)

      # The execution's own record is left running and untouched.
      platform_ctx =
        Sanctum.TestContext.platform(
          user_id: "user_b",
          permissions: [:storage_read],
          auth_method: :oidc,
          namespace: "ns_b"
        )

      assert Execution.get_tenant(Sanctum.Context.actor(platform_ctx), exec_id).status ==
               "running"

      Process.exit(target, :kill)
    end

    test "the owning tenant can cancel its running execution" do
      exec_id = "exec_cancel_owner_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Execution.record_start(%{
          id: exec_id,
          reference: "catalyst:local.test:1.0.0",
          user_id: "user_b",
          athanor_id: "ath_b",
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
          athanor_id: "ath_b",
          scope: :athanor,
          auth_method: :api_key,
          namespace: "ns_b",
          authenticated: true
        )

      assert {:ok, %{cancelled: true}} = Cyfr.Execution.Dispatch.cancel(owner_ctx, exec_id)

      # The running process is killed and the record is no longer running.
      assert_receive {:DOWN, ^ref, :process, ^target, _}, 1000

      platform_ctx =
        Sanctum.TestContext.platform(
          user_id: "user_b",
          permissions: [:storage_read],
          auth_method: :oidc,
          namespace: "ns_b"
        )

      refute Execution.get_tenant(Sanctum.Context.actor(platform_ctx), exec_id).status ==
               "running"
    end
  end

  # Spawn a process that registers itself in Cyfr.Execution.Registry under the
  # given id (mimicking a live execution) and idles until killed.
  defp register_fake_execution(execution_id) do
    test_pid = self()

    target =
      spawn(fn ->
        {:ok, _} = Registry.register(Cyfr.Execution.Registry, execution_id, %{})
        send(test_pid, :registered)
        Process.sleep(:infinity)
      end)

    assert_receive :registered, 1000
    target
  end
end
