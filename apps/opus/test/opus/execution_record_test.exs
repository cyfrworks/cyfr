# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ExecutionRecordTest do
  use ExUnit.Case, async: false

  alias Opus.ExecutionRecord
  alias Sanctum.Context

  setup do
    # Use a test-specific base path to avoid state leaking between tests
    test_path = Path.join(System.tmp_dir!(), "exec_record_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    # Checkout the Ecto sandbox to isolate SQLite data between tests
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    rand_id = :rand.uniform(100_000)

    ctx =
      Context.build(
        user_id: "exec_rec_user_#{rand_id}",
        # Unique athanor per test: executions are athanor-scoped (shared within
        # a tenant), so isolation between tests is by athanor, not user.
        athanor_id: "ath_exec_rec_#{rand_id}",
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        namespace: "testns",
        authenticated: true
      )

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: ctx, test_path: test_path}
  end

  # ============================================================================
  # Record Creation
  # ============================================================================

  describe "new/4" do
    test "creates a record with UUID execution_id", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})

      assert String.starts_with?(record.id, "exec_")
      uuid_part = String.replace_prefix(record.id, "exec_", "")
      assert String.length(uuid_part) == 36

      assert Regex.match?(
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
               uuid_part
             )
    end

    test "captures request_id from context", %{ctx: ctx} do
      ctx_with_request = %{ctx | request_id: "req_test-123"}
      record = ExecutionRecord.new(ctx_with_request, "reagent:local.test:0.1.0", %{})

      assert record.request_id == "req_test-123"
    end

    test "captures user_id from context", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})

      assert record.user_id == ctx.user_id
    end

    test "defaults to :reagent component type", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})

      assert record.component_type == :reagent
    end

    test "accepts :catalyst component type", %{ctx: ctx} do
      record =
        ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{}, component_type: :catalyst)

      assert record.component_type == :catalyst
    end

    test "accepts :formula component type", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{}, component_type: :formula)

      assert record.component_type == :formula
    end

    test "accepts component_digest option", %{ctx: ctx} do
      digest = "sha256:abc123"
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{}, component_digest: digest)

      assert record.component_digest == digest
    end

    test "accepts host_policy option", %{ctx: ctx} do
      policy = %{allowed_domains: ["api.example.com"], timeout: 30_000}
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{}, host_policy: policy)

      assert record.host_policy == policy
    end

    test "accepts parent_execution_id option", %{ctx: ctx} do
      record =
        ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{},
          parent_execution_id: "exec_parent-123"
        )

      assert record.parent_execution_id == "exec_parent-123"
    end

    test "parent_execution_id defaults to nil", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})

      assert record.parent_execution_id == nil
    end

    test "sets status to :running", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})

      assert record.status == :running
    end

    test "captures started_at timestamp", %{ctx: ctx} do
      before = DateTime.utc_now()
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})
      after_time = DateTime.utc_now()

      assert DateTime.compare(record.started_at, before) in [:gt, :eq]
      assert DateTime.compare(record.started_at, after_time) in [:lt, :eq]
    end
  end

  # ============================================================================
  # Status Transitions
  # ============================================================================

  describe "complete/3" do
    test "sets status to :completed", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})
      completed = ExecutionRecord.complete(record, %{"result" => 42})

      assert completed.status == :completed
    end

    test "captures output", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})
      output = %{"result" => 42, "data" => [1, 2, 3]}
      completed = ExecutionRecord.complete(record, output)

      assert completed.output == output
    end

    test "sets completed_at timestamp", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})
      :timer.sleep(1)
      completed = ExecutionRecord.complete(record, %{})

      assert %DateTime{} = completed.completed_at
      assert DateTime.compare(completed.completed_at, record.started_at) in [:gt, :eq]
    end

    test "calculates duration_ms", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})
      :timer.sleep(10)
      completed = ExecutionRecord.complete(record, %{})

      assert completed.duration_ms >= 10
    end
  end

  describe "fail/3" do
    test "sets status to :failed", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})
      failed = ExecutionRecord.fail(record, "Something went wrong")

      assert failed.status == :failed
    end

    test "captures error message", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})
      failed = ExecutionRecord.fail(record, "Component crashed")

      assert failed.error == "Component crashed"
    end

    test "sets completed_at timestamp", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})
      :timer.sleep(1)
      failed = ExecutionRecord.fail(record, "error")

      assert %DateTime{} = failed.completed_at
    end

    test "calculates duration_ms", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})
      :timer.sleep(10)
      failed = ExecutionRecord.fail(record, "error")

      assert failed.duration_ms >= 10
    end
  end

  # ============================================================================
  # Crash-Resilient Storage
  # ============================================================================

  describe "write_started/1" do
    test "writes execution start to SQLite", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{"a" => 1})
      :ok = ExecutionRecord.write_started(record)

      # Verify record exists in SQLite
      db_record = Arca.Repo.get(Arca.Execution, record.id)
      assert db_record != nil
      assert db_record.id == record.id
      assert db_record.user_id == record.user_id
      assert db_record.status == "running"

      # Reference is stored as a plain string (not JSON)
      assert db_record.reference == "reagent:local.test:0.1.0"

      {:ok, input} = Jason.decode(db_record.input)
      assert input == %{"a" => 1}
    end

    test "includes component_type in record", %{ctx: ctx} do
      record =
        ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{}, component_type: :catalyst)

      :ok = ExecutionRecord.write_started(record)

      db_record = Arca.Repo.get(Arca.Execution, record.id)
      assert db_record.component_type == "catalyst"
    end

    test "includes component_digest in record", %{ctx: ctx} do
      digest = "sha256:abc123def456"
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{}, component_digest: digest)
      :ok = ExecutionRecord.write_started(record)

      db_record = Arca.Repo.get(Arca.Execution, record.id)
      assert db_record.component_digest == digest
    end

    test "includes parent_execution_id in record", %{ctx: ctx} do
      record =
        ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{},
          parent_execution_id: "exec_parent-456"
        )

      :ok = ExecutionRecord.write_started(record)

      db_record = Arca.Repo.get(Arca.Execution, record.id)
      assert db_record.parent_execution_id == "exec_parent-456"
    end

    test "parent_execution_id nil when not set", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = ExecutionRecord.write_started(record)

      db_record = Arca.Repo.get(Arca.Execution, record.id)
      assert db_record.parent_execution_id == nil
    end
  end

  describe "the read round-trip" do
    test "get/2 restores the stamped activation graph; list/2 omits payloads by design",
         %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{"a" => 1})
      graph = ~s({"canonical":"jcs-1","nodes":{}})
      record = %{record | activation_graph: graph}

      :ok = ExecutionRecord.write_started(record)

      # The declared struct field survives a read — it used to be silently
      # nil on every get, though the row carried it.
      assert {:ok, read} = ExecutionRecord.get(ctx, record.id)
      assert read.activation_graph == graph

      # The list select omits payload columns (input, output, host_policy,
      # the graph) — list rows are summaries, get/2 is the full read.
      assert {:ok, [row]} = ExecutionRecord.list(ctx, limit: 5)
      assert row.activation_graph == nil
    end
  end

  describe "the row shape has one owner" do
    test "write_started's attrs are exactly the schema's start fields" do
      # The schema owns the shape; the engine's write attrs must not
      # drift from what start_changeset/1 casts.
      assert Enum.sort(Arca.Execution.start_fields()) ==
               Enum.sort(Arca.Execution.__schema__(:fields) -- [:completed_at, :duration_ms, :error_message, :output])
    end
  end

  describe "write_completed/1" do
    test "updates record with completion data", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = ExecutionRecord.write_started(record)

      completed = ExecutionRecord.complete(record, %{"result" => 42})
      :ok = ExecutionRecord.write_completed(completed)

      db_record = Arca.Repo.get(Arca.Execution, record.id)
      assert db_record.status == "completed"
      assert db_record.completed_at != nil
      assert is_integer(db_record.duration_ms)

      {:ok, output} = Jason.decode(db_record.output)
      assert output == %{"result" => 42}
    end

    test "rejects non-completed records", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})
      result = ExecutionRecord.write_completed(record)

      assert {:error, _} = result
    end
  end

  describe "write_failed/1" do
    test "updates record with failure data", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = ExecutionRecord.write_started(record)

      failed = ExecutionRecord.fail(record, "Component crashed")
      :ok = ExecutionRecord.write_failed(failed)

      db_record = Arca.Repo.get(Arca.Execution, record.id)
      assert db_record.status == "failed"
      assert db_record.error_message == "Component crashed"
    end

    test "updates record with cancelled status", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = ExecutionRecord.write_started(record)

      {:ok, cancelled} = ExecutionRecord.cancel(ctx, record.id)

      db_record = Arca.Repo.get(Arca.Execution, record.id)
      assert db_record.status == "cancelled"
      assert cancelled.status == :cancelled
    end

    test "rejects non-failed/cancelled records", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})
      result = ExecutionRecord.write_failed(record)

      assert {:error, _} = result
    end
  end

  # ============================================================================
  # Crash Detection (started without completed/failed)
  # ============================================================================

  describe "parent_execution_id roundtrip" do
    test "write_started and get roundtrip preserves parent_execution_id", %{ctx: ctx} do
      record =
        ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{},
          parent_execution_id: "exec_roundtrip-789"
        )

      :ok = ExecutionRecord.write_started(record)

      {:ok, loaded} = ExecutionRecord.get(ctx, record.id)
      assert loaded.parent_execution_id == "exec_roundtrip-789"
    end

    test "nil parent_execution_id roundtrips correctly", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = ExecutionRecord.write_started(record)

      {:ok, loaded} = ExecutionRecord.get(ctx, record.id)
      assert loaded.parent_execution_id == nil
    end
  end

  describe "crash detection" do
    test "record with only started has :running status", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = ExecutionRecord.write_started(record)

      # Load record - should show as running (crashed/interrupted)
      {:ok, loaded} = ExecutionRecord.get(ctx, record.id)

      assert loaded.status == :running
      assert loaded.completed_at == nil
    end

    test "record with started and completed has :completed status", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = ExecutionRecord.write_started(record)

      completed = ExecutionRecord.complete(record, %{"result" => 42})
      :ok = ExecutionRecord.write_completed(completed)

      {:ok, loaded} = ExecutionRecord.get(ctx, record.id)

      assert loaded.status == :completed
      assert loaded.output == %{"result" => 42}
    end

    test "record with started and failed has :failed status", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = ExecutionRecord.write_started(record)

      failed = ExecutionRecord.fail(record, "boom")
      :ok = ExecutionRecord.write_failed(failed)

      {:ok, loaded} = ExecutionRecord.get(ctx, record.id)

      assert loaded.status == :failed
      assert loaded.error == "boom"
    end
  end

  # ============================================================================
  # Concurrent Executions
  # ============================================================================

  describe "concurrent executions" do
    test "multiple concurrent executions have unique IDs", %{ctx: ctx} do
      records =
        for _ <- 1..10 do
          ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})
        end

      ids = Enum.map(records, & &1.id)
      unique_ids = Enum.uniq(ids)

      assert length(unique_ids) == 10
    end

    test "concurrent writes don't conflict", %{ctx: ctx} do
      records =
        for i <- 1..5 do
          ExecutionRecord.new(ctx, "reagent:local.test-#{i}:0.1.0", %{"i" => i})
        end

      # Write all started records concurrently
      tasks =
        for record <- records do
          Task.async(fn ->
            ExecutionRecord.write_started(record)
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, &(&1 == :ok))

      # Verify all can be loaded
      for record <- records do
        {:ok, loaded} = ExecutionRecord.get(ctx, record.id)
        assert loaded.id == record.id
      end
    end
  end

  # ============================================================================
  # List and Filter
  # ============================================================================

  describe "list/2" do
    test "returns empty list when no executions", %{ctx: ctx} do
      {:ok, records} = ExecutionRecord.list(ctx)

      assert records == []
    end

    test "returns executions sorted by started_at descending", %{ctx: ctx} do
      # Create records with small delays to ensure different timestamps
      records =
        for i <- 1..3 do
          record = ExecutionRecord.new(ctx, "reagent:local.test-#{i}:0.1.0", %{})
          :ok = ExecutionRecord.write_started(record)
          :timer.sleep(10)
          record
        end

      {:ok, loaded} = ExecutionRecord.list(ctx)

      # Most recent first
      assert length(loaded) == 3
      assert hd(loaded).id == List.last(records).id
    end

    test "respects limit option", %{ctx: ctx} do
      for i <- 1..5 do
        record = ExecutionRecord.new(ctx, "reagent:local.test-#{i}:0.1.0", %{})
        :ok = ExecutionRecord.write_started(record)
      end

      {:ok, loaded} = ExecutionRecord.list(ctx, limit: 2)

      assert length(loaded) == 2
    end

    test "filters by status", %{ctx: ctx} do
      # Create one running and one completed
      running = ExecutionRecord.new(ctx, "reagent:local.running:0.1.0", %{})
      :ok = ExecutionRecord.write_started(running)

      completed_record = ExecutionRecord.new(ctx, "reagent:local.completed:0.1.0", %{})
      :ok = ExecutionRecord.write_started(completed_record)
      completed = ExecutionRecord.complete(completed_record, %{})
      :ok = ExecutionRecord.write_completed(completed)

      # Filter by running
      {:ok, running_list} = ExecutionRecord.list(ctx, status: :running)
      assert length(running_list) == 1
      assert hd(running_list).status == :running

      # Filter by completed
      {:ok, completed_list} = ExecutionRecord.list(ctx, status: :completed)
      assert length(completed_list) == 1
      assert hd(completed_list).status == :completed
    end
  end

  # ============================================================================
  # Cancel
  # ============================================================================

  describe "cancel/2" do
    test "cancels a running execution", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = ExecutionRecord.write_started(record)

      {:ok, cancelled} = ExecutionRecord.cancel(ctx, record.id)

      assert cancelled.status == :cancelled
    end

    test "returns error for completed execution", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = ExecutionRecord.write_started(record)
      completed = ExecutionRecord.complete(record, %{})
      :ok = ExecutionRecord.write_completed(completed)

      result = ExecutionRecord.cancel(ctx, record.id)

      assert {:error, :not_cancellable} = result
    end

    test "returns error for non-existent execution", %{ctx: ctx} do
      result = ExecutionRecord.cancel(ctx, "exec_nonexistent")

      assert {:error, :not_found} = result
    end
  end

  # ============================================================================
  # Reference Normalization
  # ============================================================================

  describe "reference normalization" do
    test "string reference is stored as-is", %{ctx: ctx} do
      ref = "catalyst:local.gemini:0.1.0"
      record = ExecutionRecord.new(ctx, ref, %{})
      :ok = ExecutionRecord.write_started(record)

      db_record = Arca.Repo.get(Arca.Execution, record.id)
      assert db_record.reference == "catalyst:local.gemini:0.1.0"
    end

    test "string reference roundtrips through parse_reference", %{ctx: ctx} do
      ref = "formula:local.list-models:0.1.0"
      record = ExecutionRecord.new(ctx, ref, %{})
      :ok = ExecutionRecord.write_started(record)

      {:ok, loaded} = ExecutionRecord.get(ctx, record.id)
      assert loaded.reference == "formula:local.list-models:0.1.0"
    end
  end

  # ============================================================================
  # Correlation ID Format
  # ============================================================================

  describe "correlation ID format" do
    test "execution_id follows exec_<uuid> format", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})

      assert String.starts_with?(record.id, "exec_")

      uuid_part = String.replace_prefix(record.id, "exec_", "")
      # UUID format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
      assert Regex.match?(
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
               uuid_part
             )
    end

    test "execution IDs are unique", %{ctx: ctx} do
      record1 = ExecutionRecord.new(ctx, "reagent:local.test1:0.1.0", %{})
      record2 = ExecutionRecord.new(ctx, "reagent:local.test2:0.1.0", %{})

      assert record1.id != record2.id
    end
  end
end
