# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExecutionTest do
  use ExUnit.Case, async: false

  alias Arca.Execution

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  describe "start_changeset/1" do
    test "creates valid changeset with required fields" do
      attrs = %{
        id: "exec_test123",
        reference: ~s({"local": "./test.wasm"}),
        user_id: "user_abc",
        started_at: DateTime.utc_now(),
        status: "running",
        component_type: "reagent"
      }

      changeset = Execution.start_changeset(attrs)
      assert changeset.valid?
    end

    test "requires an explicit component_type and rejects non-executable types" do
      base = %{
        id: "exec_type_check",
        reference: ~s({"local": "./test.wasm"}),
        user_id: "user_abc",
        started_at: DateTime.utc_now(),
        status: "running"
      }

      # No silent "reagent" default — the writer must state the type.
      refute Execution.start_changeset(base).valid?

      # Tinctures are browser-side and never execute through Opus.
      refute Execution.start_changeset(Map.put(base, :component_type, "tincture")).valid?

      for type <- Sanctum.ComponentRef.executable_types() do
        assert Execution.start_changeset(Map.put(base, :component_type, type)).valid?
      end
    end

    test "requires id" do
      attrs = %{
        reference: ~s({"local": "./test.wasm"}),
        user_id: "user_abc",
        started_at: DateTime.utc_now(),
        status: "running"
      }

      changeset = Execution.start_changeset(attrs)
      refute changeset.valid?
      assert {:id, _} = hd(changeset.errors)
    end

    test "requires reference" do
      attrs = %{
        id: "exec_test123",
        user_id: "user_abc",
        started_at: DateTime.utc_now(),
        status: "running"
      }

      changeset = Execution.start_changeset(attrs)
      refute changeset.valid?
      assert {:reference, _} = hd(changeset.errors)
    end

    test "validates status inclusion" do
      attrs = %{
        id: "exec_test123",
        reference: ~s({"local": "./test.wasm"}),
        user_id: "user_abc",
        started_at: DateTime.utc_now(),
        status: "invalid_status"
      }

      changeset = Execution.start_changeset(attrs)
      refute changeset.valid?
      assert {:status, _} = hd(changeset.errors)
    end

    test "validates component_type inclusion" do
      attrs = %{
        id: "exec_test123",
        reference: ~s({"local": "./test.wasm"}),
        user_id: "user_abc",
        started_at: DateTime.utc_now(),
        status: "running",
        component_type: "invalid_type"
      }

      changeset = Execution.start_changeset(attrs)
      refute changeset.valid?
      assert {:component_type, _} = hd(changeset.errors)
    end

    test "accepts optional fields" do
      attrs = %{
        id: "exec_test123",
        reference: ~s({"local": "./test.wasm"}),
        user_id: "user_abc",
        started_at: DateTime.utc_now(),
        status: "running",
        component_type: "catalyst",
        component_digest: "sha256:abc123",
        input_hash: "def456"
      }

      changeset = Execution.start_changeset(attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :component_type) == "catalyst"
      assert Ecto.Changeset.get_field(changeset, :component_digest) == "sha256:abc123"
    end
  end

  describe "complete_changeset/2" do
    test "creates valid changeset for completion" do
      execution = %Execution{
        id: "exec_test123",
        reference: ~s({"local": "./test.wasm"}),
        user_id: "user_abc",
        started_at: DateTime.utc_now(),
        status: "running"
      }

      attrs = %{
        completed_at: DateTime.utc_now(),
        duration_ms: 150,
        status: "completed"
      }

      changeset = Execution.complete_changeset(execution, attrs)
      assert changeset.valid?
    end

    test "accepts error_message for failed status" do
      execution = %Execution{
        id: "exec_test123",
        reference: ~s({"local": "./test.wasm"}),
        user_id: "user_abc",
        started_at: DateTime.utc_now(),
        status: "running"
      }

      attrs = %{
        completed_at: DateTime.utc_now(),
        duration_ms: 50,
        status: "failed",
        error_message: "Component crashed"
      }

      changeset = Execution.complete_changeset(execution, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :error_message) == "Component crashed"
    end

    test "validates status for completion" do
      execution = %Execution{id: "exec_test123", status: "running"}

      # Invalid status for completion
      attrs = %{
        completed_at: DateTime.utc_now(),
        duration_ms: 100,
        status: "invalid_status"
      }

      changeset = Execution.complete_changeset(execution, attrs)
      refute changeset.valid?
      assert {:status, _} = hd(changeset.errors)
    end
  end

  describe "list_running_children/1" do
    test "returns children with running status" do
      parent_id = "exec_parent_#{System.unique_integer([:positive])}"
      child_id = "exec_child_#{System.unique_integer([:positive])}"
      now = DateTime.utc_now()

      {:ok, _} =
        Execution.record_start(%{
          id: parent_id,
          reference: "formula:local.test:1.0.0",
          user_id: "user_test",
          started_at: now,
          status: "running",
          component_type: "formula"
        })

      {:ok, _} =
        Execution.record_start(%{
          id: child_id,
          reference: "catalyst:local.child:1.0.0",
          user_id: "user_test",
          started_at: now,
          status: "running",
          component_type: "catalyst",
          parent_execution_id: parent_id
        })

      children = Execution.list_running_children(parent_id)
      assert length(children) == 1
      assert hd(children).id == child_id
    end

    test "does not return completed children" do
      parent_id = "exec_parent_#{System.unique_integer([:positive])}"
      child_id = "exec_child_#{System.unique_integer([:positive])}"
      now = DateTime.utc_now()

      {:ok, _} =
        Execution.record_start(%{
          id: parent_id,
          reference: "formula:local.test:1.0.0",
          user_id: "user_test",
          started_at: now,
          status: "running",
          component_type: "formula"
        })

      {:ok, _} =
        Execution.record_start(%{
          id: child_id,
          reference: "catalyst:local.child:1.0.0",
          user_id: "user_test",
          started_at: now,
          status: "running",
          component_type: "catalyst",
          parent_execution_id: parent_id
        })

      # Complete the child
      ctx = Sanctum.Context.build(user_id: "user_test", permissions: [:execution_write], scope: :project, auth_method: :oidc, namespace: "testns", authenticated: true)
      {:ok, _} = Execution.record_complete(ctx, child_id, %{completed_at: now, duration_ms: 100, status: "completed"})

      children = Execution.list_running_children(parent_id)
      assert children == []
    end

    test "returns empty list when no children exist" do
      children = Execution.list_running_children("exec_nonexistent")
      assert children == []
    end
  end

  describe "mark_failed_if_running/2" do
    test "marks running execution as failed" do
      id = "exec_mark_#{System.unique_integer([:positive])}"
      now = DateTime.utc_now()

      {:ok, _} =
        Execution.record_start(%{
          id: id,
          reference: "catalyst:local.test:1.0.0",
          user_id: "user_test",
          started_at: now,
          status: "running",
          component_type: "catalyst"
        })

      {count, _} =
        Execution.mark_failed_if_running(id, %{
          completed_at: now,
          duration_ms: 500,
          error_message: "Parent terminated"
        })

      assert count == 1

      ctx = Sanctum.Context.build(user_id: "user_test", permissions: [:execution_read], scope: :platform, auth_method: :oidc, namespace: "testns", authenticated: true)
      updated = Execution.get_tenant(ctx, id)
      assert updated.status == "failed"
      assert updated.error_message == "Parent terminated"
    end

    test "does not overwrite already-completed execution" do
      id = "exec_mark_#{System.unique_integer([:positive])}"
      now = DateTime.utc_now()

      {:ok, _} =
        Execution.record_start(%{
          id: id,
          reference: "catalyst:local.test:1.0.0",
          user_id: "user_test",
          started_at: now,
          status: "running",
          component_type: "catalyst"
        })

      # Complete it first
      ctx = Sanctum.Context.build(user_id: "user_test", permissions: [:execution_write], scope: :project, auth_method: :oidc, namespace: "testns", authenticated: true)
      {:ok, _} = Execution.record_complete(ctx, id, %{completed_at: now, duration_ms: 100, status: "completed"})

      # Try to mark as failed — should be a no-op
      {count, _} =
        Execution.mark_failed_if_running(id, %{
          completed_at: now,
          duration_ms: 500,
          error_message: "Parent terminated"
        })

      assert count == 0

      updated = Execution.get_tenant(ctx, id)
      assert updated.status == "completed"
    end
  end

  describe "list_stale_running/2" do
    test "returns running executions older than cutoff" do
      id = "exec_stale_#{System.unique_integer([:positive])}"
      old_time = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, _} =
        Execution.record_start(%{
          id: id,
          reference: "catalyst:local.test:1.0.0",
          user_id: "user_test",
          started_at: old_time,
          status: "running",
          component_type: "catalyst"
        })

      cutoff = DateTime.add(DateTime.utc_now(), -600, :second)
      stale = Execution.list_stale_running(cutoff)
      stale_ids = Enum.map(stale, & &1.id)
      assert id in stale_ids
    end

    test "does not return recent running executions" do
      id = "exec_recent_#{System.unique_integer([:positive])}"
      now = DateTime.utc_now()

      {:ok, _} =
        Execution.record_start(%{
          id: id,
          reference: "catalyst:local.test:1.0.0",
          user_id: "user_test",
          started_at: now,
          status: "running",
          component_type: "catalyst"
        })

      cutoff = DateTime.add(DateTime.utc_now(), -600, :second)
      stale = Execution.list_stale_running(cutoff)
      stale_ids = Enum.map(stale, & &1.id)
      refute id in stale_ids
    end

    test "respects limit parameter" do
      # Create multiple stale records
      old_time = DateTime.add(DateTime.utc_now(), -3600, :second)

      for i <- 1..3 do
        {:ok, _} =
          Execution.record_start(%{
            id: "exec_limit_#{System.unique_integer([:positive])}_#{i}",
            reference: "catalyst:local.test:1.0.0",
            user_id: "user_test",
            started_at: old_time,
            status: "running",
            component_type: "catalyst"
          })
      end

      cutoff = DateTime.add(DateTime.utc_now(), -600, :second)
      stale = Execution.list_stale_running(cutoff, 1)
      assert length(stale) == 1
    end
  end

  describe "hash_input/1" do
    test "returns consistent hash for same input" do
      input = %{"method" => "GET", "url" => "https://example.com"}

      hash1 = Execution.hash_input(input)
      hash2 = Execution.hash_input(input)

      assert hash1 == hash2
      assert is_binary(hash1)
      # SHA256 hex is 64 chars
      assert String.length(hash1) == 64
    end

    test "returns different hash for different input" do
      input1 = %{"method" => "GET"}
      input2 = %{"method" => "POST"}

      hash1 = Execution.hash_input(input1)
      hash2 = Execution.hash_input(input2)

      refute hash1 == hash2
    end

    test "returns nil for non-map input" do
      assert Execution.hash_input(nil) == nil
      assert Execution.hash_input("string") == nil
      assert Execution.hash_input(123) == nil
    end

    test "returns nil for non-encodable map input" do
      # A map with a PID value cannot be JSON-encoded
      assert Execution.hash_input(%{"pid" => self()}) == nil
    end
  end
end
