# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.RecordTest do
  use ExUnit.Case, async: false

  alias Cyfr.Execution.Record
  alias Sanctum.Context

  setup do
    # Use a test-specific base path to avoid state leaking between tests
    test_path = Path.join(System.tmp_dir!(), "exec_record_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

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

    # A run is admitted only in an estate that stands: the test's own has a row.
    Arca.Test.Actor.athanor!(ctx.athanor_id)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: ctx, test_path: test_path}
  end

  # ============================================================================
  # Record Creation
  # ============================================================================

  describe "new/4" do
    test "creates a record with UUID execution_id", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})

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
      record = Record.new(ctx_with_request, "reagent:local.test:0.1.0", %{})

      assert record.request_id == "req_test-123"
    end

    test "captures user_id from context", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})

      assert record.user_id == ctx.user_id
    end

    test "defaults to :reagent component type", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})

      assert record.component_type == :reagent
    end

    test "accepts :catalyst component type", %{ctx: ctx} do
      record =
        Record.new(ctx, "reagent:local.test:0.1.0", %{}, component_type: :catalyst)

      assert record.component_type == :catalyst
    end

    test "accepts :formula component type", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{}, component_type: :formula)

      assert record.component_type == :formula
    end

    test "accepts component_digest option", %{ctx: ctx} do
      digest = "sha256:abc123"
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{}, component_digest: digest)

      assert record.component_digest == digest
    end

    test "accepts host_policy option", %{ctx: ctx} do
      policy = %{allowed_domains: ["api.example.com"], timeout: 30_000}
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{}, host_policy: policy)

      assert record.host_policy == policy
    end

    test "accepts parent_execution_id option", %{ctx: ctx} do
      record =
        Record.new(ctx, "reagent:local.test:0.1.0", %{}, parent_execution_id: "exec_parent-123")

      assert record.parent_execution_id == "exec_parent-123"
    end

    test "parent_execution_id defaults to nil", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})

      assert record.parent_execution_id == nil
    end

    test "sets status to :running", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})

      assert record.status == :running
    end

    test "captures started_at timestamp", %{ctx: ctx} do
      before = DateTime.utc_now()
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
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
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      completed = Record.complete(record, %{"result" => 42})

      assert completed.status == :completed
    end

    test "captures output", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      output = %{"result" => 42, "data" => [1, 2, 3]}
      completed = Record.complete(record, output)

      assert completed.output == output
    end

    test "sets completed_at timestamp", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      :timer.sleep(1)
      completed = Record.complete(record, %{})

      assert %DateTime{} = completed.completed_at
      assert DateTime.compare(completed.completed_at, record.started_at) in [:gt, :eq]
    end

    test "calculates duration_ms", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      :timer.sleep(10)
      completed = Record.complete(record, %{})

      assert completed.duration_ms >= 10
    end
  end

  describe "fail/3" do
    test "sets status to :failed", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      failed = Record.fail(record, "Something went wrong")

      assert failed.status == :failed
    end

    test "captures error message", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      failed = Record.fail(record, "Component crashed")

      assert failed.error == "Component crashed"
    end

    test "sets completed_at timestamp", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      :timer.sleep(1)
      failed = Record.fail(record, "error")

      assert %DateTime{} = failed.completed_at
    end

    test "calculates duration_ms", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      :timer.sleep(10)
      failed = Record.fail(record, "error")

      assert failed.duration_ms >= 10
    end
  end

  # ============================================================================
  # Crash-Resilient Storage
  # ============================================================================

  describe "write_started/1" do
    test "writes execution start to SQLite", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{"a" => 1})
      :ok = Record.write_started(record)

      # Verify record exists in SQLite
      db_record = Arca.Repo.get(Arca.Execution, record.id)
      assert db_record != nil
      assert db_record.id == record.id
      assert db_record.user_id == record.user_id
      assert db_record.status == "running"

      # Reference is stored as a plain string (not JSON)
      assert db_record.reference == "reagent:local.test:0.1.0"

      # The row keeps an envelope of the input, never the input: what ran,
      # a digest to tell inputs apart, sizes and keys.
      {:ok, input} = Jason.decode(db_record.input)
      assert input["envelope"] == "v1"
      assert input["reference"] == "reagent:local.test:0.1.0"
      assert input["keys"] == ["a"]
      assert input["bytes"] == byte_size(Jason.encode!(%{"a" => 1}))
      assert input["input_hash"] == Arca.Execution.hash_input(%{"a" => 1})
      assert db_record.input_hash == input["input_hash"]
      refute Map.has_key?(input, "a")
    end

    test "attachments persist as digests, never as bytes", %{ctx: ctx} do
      data = Base.encode64("secret bytes")

      record =
        Record.new(ctx, "formula:local.demo:1.0.0", %{
          "task" => "look at this",
          "attachments" => [
            %{"filename" => "a.txt", "media_type" => "text/plain", "data" => data}
          ]
        })

      :ok = Record.write_started(record)
      {:ok, input} = Jason.decode(Arca.Repo.get(Arca.Execution, record.id).input)

      assert [%{"filename" => "a.txt", "media_type" => "text/plain", "bytes" => _, "digest" => _}] =
               input["attachments"]

      refute String.contains?(Jason.encode!(input), data)
      refute String.contains?(Jason.encode!(input), "look at this")
    end

    test "every output is an envelope on the row and bytes in the payload store, read back joined",
         %{ctx: ctx} do
      root =
        Record.new(ctx, "agent:local.aqua", %{"turn" => "trn_1"},
          kind: "turn",
          component_type: :agent,
          retention_class: "chat_step"
        )

      # A child is admitted under the grant its parent's attempt stores:
      # the root is a row, admitted with no payload of its own.
      {:ok, _} =
        Arca.Execution.admit(
          %{
            id: root.id,
            reference: "agent:local.aqua",
            user_id: ctx.user_id,
            athanor_id: ctx.athanor_id,
            component_type: "agent",
            kind: "turn"
          },
          Cyfr.Test.AttemptFixtures.standing(ctx.athanor_id)
        )

      child =
        Record.new(ctx, "catalyst:moonmoon69.claude:1.0.0", %{"messages" => []},
          parent_execution_id: root.id,
          retention_class: "chat_step"
        )

      :ok = Record.write_started(child)

      # A `model/chat@1` answer, as its catalyst completes it: the usage is
      # the answer's data's.
      reply = %{
        "status" => 200,
        "data" => %{
          "content" => [%{"type" => "text", "text" => "the reply"}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 9, "output_tokens" => 2}
        }
      }

      :ok = Record.write_completed(Record.complete(child, reply))
      {:ok, output} = Jason.decode(Arca.Repo.get(Arca.Execution, child.id).output)

      assert output["envelope"] == "v1"
      assert output["usage"] == %{"input_tokens" => 9, "output_tokens" => 2}
      assert output["output_hash"] == Cyfr.Digest.sha256(Jason.encode!(reply))
      refute String.contains?(Jason.encode!(output), "the reply")

      # The bytes are the attempt's payload, under the record's class; the
      # input was kept with admission.
      assert {:ok, %{retention_class: "chat_step", attempt: attempt}, bytes} =
               Arca.ExecutionPayloads.get(Sanctum.Context.actor(ctx), child.id, "result")

      assert attempt == child.attempt
      assert Jason.decode!(bytes) == reply

      assert {:ok, _, input} =
               Arca.ExecutionPayloads.get(Sanctum.Context.actor(ctx), child.id, "input")

      assert Jason.decode!(input) == %{"messages" => []}

      # A read joins them back; swept, the envelope alone answers.
      assert {:ok, %{output: ^reply}} = Record.get(ctx, child.id)
      old = DateTime.add(DateTime.utc_now(), -2 * 86_400, :second)
      {2, _} = Arca.Repo.update_all(Arca.Schemas.ExecutionPayload, set: [inserted_at: old])

      {:ok, 2} =
        Arca.ExecutionPayloads.delete_older_than_days(Sanctum.Context.actor(ctx), 1, ["chat_step"])

      assert {:ok, %{output: %{"envelope" => "v1"}}} = Record.get(ctx, child.id)
    end

    test "usage is what a model answer's data carries: a field another output names so is its own",
         %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{"a" => 1})
      :ok = Record.write_started(record)
      :ok = Record.write_completed(Record.complete(record, %{"usage" => %{"input_tokens" => 9}}))

      assert {:ok, %{"envelope" => "v1", "usage" => nil}} =
               Jason.decode(Arca.Repo.get(Arca.Execution, record.id).output)
    end

    test "a refused model answer carries no usage", %{ctx: ctx} do
      record = Record.new(ctx, "catalyst:moonmoon69.claude:1.0.0", %{"messages" => []})
      :ok = Record.write_started(record)

      refused = %{
        "status" => 429,
        "error" => %{"type" => "rate_limited", "message" => "slow down"}
      }

      :ok = Record.write_completed(Record.complete(record, refused))

      assert {:ok, %{"envelope" => "v1", "usage" => nil}} =
               Jason.decode(Arca.Repo.get(Arca.Execution, record.id).output)
    end

    test "any other component's output is the same shape, under its own class", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{"a" => 1})
      assert record.retention_class == "api"
      :ok = Record.write_started(record)
      :ok = Record.write_completed(Record.complete(record, %{"sum" => 2}))

      assert {:ok, %{"envelope" => "v1"}} =
               Jason.decode(Arca.Repo.get(Arca.Execution, record.id).output)

      assert {:ok, %{retention_class: "api"}, bytes} =
               Arca.ExecutionPayloads.get(Sanctum.Context.actor(ctx), record.id, "result")

      assert Jason.decode!(bytes) == %{"sum" => 2}
      assert {:ok, %{output: %{"sum" => 2}}} = Record.get(ctx, record.id)
    end

    test "a result that cannot be kept closes the attempt result_lost, never as completed",
         %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{"a" => 1})
      :ok = Record.write_started(record)

      Application.put_env(:arca, :execution_payload_store, __MODULE__.RefusingStore)
      on_exit(fn -> Application.delete_env(:arca, :execution_payload_store) end)

      assert {:error, {:result_lost, :disk_full}} =
               Record.write_completed(Record.complete(record, %{"sum" => 2}))

      row = Arca.Repo.get(Arca.Execution, record.id)
      assert row.status == "failed"
      assert row.error_message == "result not retained"

      assert %{state: "failed", outcome: "result_lost"} =
               Arca.ExecutionAttempts.current(Sanctum.Context.actor(ctx), record.id)

      # An input that cannot be kept admits nothing.
      other = Record.new(ctx, "reagent:local.test:0.1.0", %{"b" => 2})
      assert {:error, {:payload_not_retained, :disk_full}} = Record.write_started(other)
      assert Arca.Repo.get(Arca.Execution, other.id) == nil
    end

    test "includes component_type in record", %{ctx: ctx} do
      record =
        Record.new(ctx, "reagent:local.test:0.1.0", %{}, component_type: :catalyst)

      :ok = Record.write_started(record)

      db_record = Arca.Repo.get(Arca.Execution, record.id)
      assert db_record.component_type == "catalyst"
    end

    test "includes component_digest in record", %{ctx: ctx} do
      digest = "sha256:abc123def456"
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{}, component_digest: digest)
      :ok = Record.write_started(record)

      db_record = Arca.Repo.get(Arca.Execution, record.id)
      assert db_record.component_digest == digest
    end

    test "includes parent_execution_id in record", %{ctx: ctx} do
      parent = parent!(ctx)

      record =
        Record.new(ctx, "reagent:local.test:0.1.0", %{}, parent_execution_id: parent)

      :ok = Record.write_started(record)

      db_record = Arca.Repo.get(Arca.Execution, record.id)
      assert db_record.parent_execution_id == parent
    end

    test "a child whose parent is not a row is admitted under no grant", %{ctx: ctx} do
      record =
        Record.new(ctx, "reagent:local.test:0.1.0", %{}, parent_execution_id: "exec_parent-456")

      assert {:error, :not_standing} = Record.write_started(record)
      refute Arca.Repo.get(Arca.Execution, record.id)
    end

    test "parent_execution_id nil when not set", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = Record.write_started(record)

      db_record = Arca.Repo.get(Arca.Execution, record.id)
      assert db_record.parent_execution_id == nil
    end
  end

  describe "the read round-trip" do
    test "get/2 restores the stamped activation graph; list/2 omits payloads by design",
         %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{"a" => 1})
      graph = ~s({"canonical":"jcs-1","nodes":{}})
      record = %{record | activation_graph: graph}

      :ok = Record.write_started(record)

      # The declared struct field must survive a database read.
      assert {:ok, read} = Record.get(ctx, record.id)
      assert read.activation_graph == graph

      # The list select omits payload columns (input, output, host_policy,
      # the graph) — list rows are summaries, get/2 is the full read.
      assert {:ok, [row]} = Record.list(ctx, limit: 5)
      assert row.activation_graph == nil
    end
  end

  describe "the row shape has one owner" do
    test "write_started's attrs are exactly the schema's start fields" do
      # The schema owns the shape; the engine's write attrs must not
      # drift from what start_changeset/1 casts.
      assert Enum.sort(Arca.Execution.start_fields()) ==
               Enum.sort(
                 Arca.Execution.__schema__(:fields) --
                   [:completed_at, :duration_ms, :error_message, :output]
               )
    end
  end

  describe "write_completed/1" do
    test "updates record with completion data", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = Record.write_started(record)

      completed = Record.complete(record, %{"result" => 42})
      :ok = Record.write_completed(completed)

      db_record = Arca.Repo.get(Arca.Execution, record.id)
      assert db_record.status == "completed"
      assert db_record.completed_at != nil
      assert is_integer(db_record.duration_ms)

      {:ok, output} = Jason.decode(db_record.output)
      assert output["envelope"] == "v1"
    end

    test "rejects non-completed records", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      result = Record.write_completed(record)

      assert {:error, _} = result
    end
  end

  describe "write_failed/1" do
    test "updates record with failure data", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = Record.write_started(record)

      failed = Record.fail(record, "Component crashed")
      :ok = Record.write_failed(failed)

      db_record = Arca.Repo.get(Arca.Execution, record.id)
      assert db_record.status == "failed"
      assert db_record.error_message == "Component crashed"
    end

    test "updates record with cancelled status", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = Record.write_started(record)

      {:ok, cancelled} = Record.cancel(ctx, record.id)

      db_record = Arca.Repo.get(Arca.Execution, record.id)
      assert db_record.status == "cancelled"
      assert cancelled.status == :cancelled
    end

    test "rejects non-failed/cancelled records", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      result = Record.write_failed(record)

      assert {:error, _} = result
    end
  end

  # ============================================================================
  # Crash Detection (started without completed/failed)
  # ============================================================================

  describe "parent_execution_id roundtrip" do
    test "write_started and get roundtrip preserves parent_execution_id", %{ctx: ctx} do
      parent = parent!(ctx)

      record =
        Record.new(ctx, "reagent:local.test:0.1.0", %{}, parent_execution_id: parent)

      :ok = Record.write_started(record)

      {:ok, loaded} = Record.get(ctx, record.id)
      assert loaded.parent_execution_id == parent
    end

    test "nil parent_execution_id roundtrips correctly", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = Record.write_started(record)

      {:ok, loaded} = Record.get(ctx, record.id)
      assert loaded.parent_execution_id == nil
    end
  end

  describe "crash detection" do
    test "record with only started has :running status", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = Record.write_started(record)

      # Load record - should show as running (crashed/interrupted)
      {:ok, loaded} = Record.get(ctx, record.id)

      assert loaded.status == :running
      assert loaded.completed_at == nil
    end

    test "record with started and completed has :completed status", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = Record.write_started(record)

      completed = Record.complete(record, %{"result" => 42})
      :ok = Record.write_completed(completed)

      {:ok, loaded} = Record.get(ctx, record.id)

      assert loaded.status == :completed
      assert loaded.output == %{"result" => 42}
    end

    test "record with started and failed has :failed status", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = Record.write_started(record)

      failed = Record.fail(record, "boom")
      :ok = Record.write_failed(failed)

      {:ok, loaded} = Record.get(ctx, record.id)

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
          Record.new(ctx, "reagent:local.test:0.1.0", %{})
        end

      ids = Enum.map(records, & &1.id)
      unique_ids = Enum.uniq(ids)

      assert length(unique_ids) == 10
    end

    test "concurrent writes don't conflict", %{ctx: ctx} do
      records =
        for i <- 1..5 do
          Record.new(ctx, "reagent:local.test-#{i}:0.1.0", %{"i" => i})
        end

      # Write all started records concurrently
      tasks =
        for record <- records do
          Task.async(fn ->
            Record.write_started(record)
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, &(&1 == :ok))

      # Verify all can be loaded
      for record <- records do
        {:ok, loaded} = Record.get(ctx, record.id)
        assert loaded.id == record.id
      end
    end
  end

  # ============================================================================
  # List and Filter
  # ============================================================================

  describe "list/2" do
    test "returns empty list when no executions", %{ctx: ctx} do
      {:ok, records} = Record.list(ctx)

      assert records == []
    end

    test "returns executions sorted by started_at descending", %{ctx: ctx} do
      # Create records with small delays to ensure different timestamps
      records =
        for i <- 1..3 do
          record = Record.new(ctx, "reagent:local.test-#{i}:0.1.0", %{})
          :ok = Record.write_started(record)
          :timer.sleep(10)
          record
        end

      {:ok, loaded} = Record.list(ctx)

      # Most recent first
      assert length(loaded) == 3
      assert hd(loaded).id == List.last(records).id
    end

    test "respects limit option", %{ctx: ctx} do
      for i <- 1..5 do
        record = Record.new(ctx, "reagent:local.test-#{i}:0.1.0", %{})
        :ok = Record.write_started(record)
      end

      {:ok, loaded} = Record.list(ctx, limit: 2)

      assert length(loaded) == 2
    end

    test "filters by status", %{ctx: ctx} do
      # Create one running and one completed
      running = Record.new(ctx, "reagent:local.running:0.1.0", %{})
      :ok = Record.write_started(running)

      completed_record = Record.new(ctx, "reagent:local.completed:0.1.0", %{})
      :ok = Record.write_started(completed_record)
      completed = Record.complete(completed_record, %{})
      :ok = Record.write_completed(completed)

      # Filter by running
      {:ok, running_list} = Record.list(ctx, status: :running)
      assert length(running_list) == 1
      assert hd(running_list).status == :running

      # Filter by completed
      {:ok, completed_list} = Record.list(ctx, status: :completed)
      assert length(completed_list) == 1
      assert hd(completed_list).status == :completed
    end
  end

  # ============================================================================
  # Cancel
  # ============================================================================

  describe "lifecycle events" do
    test "every write appends its row, numbered in order, and a lost result is its own kind",
         %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{"a" => 1})
      :ok = Record.write_started(record)
      :ok = Record.write_completed(Record.complete(record, %{"sum" => 2}))

      {:ok, rows} = Arca.ExecutionEvents.since(Sanctum.Context.actor(ctx), record.id, 0)

      assert [
               %{seq: 1, type: "execution.started"},
               %{seq: 2, type: "execution.completed"}
             ] = rows

      assert %{"attempt" => attempt} = Arca.ExecutionEvents.data(hd(rows))
      assert attempt == record.attempt
      assert %{"status" => "completed"} = Arca.ExecutionEvents.data(List.last(rows))

      failed = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = Record.write_started(failed)
      :ok = Record.write_failed(Record.fail(failed, "boom"))

      assert {:ok, [_, %{type: "execution.failed"} = row]} =
               Arca.ExecutionEvents.since(Sanctum.Context.actor(ctx), failed.id, 0)

      assert %{"error" => "boom"} = Arca.ExecutionEvents.data(row)

      lost = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = Record.write_started(lost)
      Application.put_env(:arca, :execution_payload_store, __MODULE__.RefusingStore)
      on_exit(fn -> Application.delete_env(:arca, :execution_payload_store) end)

      {:error, {:result_lost, _}} =
        Record.write_completed(Record.complete(lost, %{"sum" => 2}))

      assert {:ok, [_, %{type: "execution.result_lost"}]} =
               Arca.ExecutionEvents.since(Sanctum.Context.actor(ctx), lost.id, 0)
    end

    test "a cancel that asks for a restart says so on its event", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = Record.write_started(record)

      {:ok, _} =
        Record.cancel(ctx, record.id, restart_required: %{"profile_id" => "prof_1"})

      assert {:ok, [_, %{type: "execution.cancelled"} = row]} =
               Arca.ExecutionEvents.since(Sanctum.Context.actor(ctx), record.id, 0)

      assert %{"restart_required" => %{"profile_id" => "prof_1"}} =
               Arca.ExecutionEvents.data(row)
    end
  end

  describe "cancel/2" do
    @tag capture_log: true
    test "an unavailable execution table returns the storage refusal without cancelling", %{
      ctx: ctx
    } do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = Record.write_started(record)

      # DDL stays inside this synchronous test's sandbox transaction.
      Ecto.Adapters.SQL.query!(
        Arca.Repo,
        "ALTER TABLE executions RENAME TO unavailable_executions"
      )

      try do
        assert {:error, :database_error} = Record.cancel(ctx, record.id)
      after
        Ecto.Adapters.SQL.query!(
          Arca.Repo,
          "ALTER TABLE unavailable_executions RENAME TO executions"
        )
      end

      assert {:ok, %{status: :running}} = Record.get(ctx, record.id)
    end

    test "cancels a running execution", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = Record.write_started(record)

      {:ok, cancelled} = Record.cancel(ctx, record.id)

      assert cancelled.status == :cancelled
    end

    test "returns error for completed execution", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = Record.write_started(record)
      completed = Record.complete(record, %{})
      :ok = Record.write_completed(completed)

      result = Record.cancel(ctx, record.id)

      assert {:error, :not_cancellable} = result
    end

    test "returns error for non-existent execution", %{ctx: ctx} do
      result = Record.cancel(ctx, "exec_nonexistent")

      assert {:error, :not_found} = result
    end
  end

  # ============================================================================
  # Reference Normalization
  # ============================================================================

  describe "reference normalization" do
    test "string reference is stored as-is", %{ctx: ctx} do
      ref = "catalyst:local.gemini:0.1.0"
      record = Record.new(ctx, ref, %{})
      :ok = Record.write_started(record)

      db_record = Arca.Repo.get(Arca.Execution, record.id)
      assert db_record.reference == "catalyst:local.gemini:0.1.0"
    end

    test "string reference roundtrips through parse_reference", %{ctx: ctx} do
      ref = "formula:local.list-models:0.1.0"
      record = Record.new(ctx, ref, %{})
      :ok = Record.write_started(record)

      {:ok, loaded} = Record.get(ctx, record.id)
      assert loaded.reference == "formula:local.list-models:0.1.0"
    end
  end

  describe "executable_type/1" do
    test "names each executable type by its atom" do
      for type <- Cyfr.ComponentRef.executable_types() do
        assert {:ok, atom} = Record.executable_type(type)
        assert Atom.to_string(atom) == type
      end
    end

    test "is :error for a turn root, a tincture, an unknown type and an empty column" do
      for type <- ["agent", "tincture", "widget", nil, :catalyst] do
        assert Record.executable_type(type) == :error
      end
    end

    test "a read-back row carries its executable type, a turn root :agent", %{ctx: ctx} do
      formula = Record.new(ctx, "formula:local.demo:1.0.0", %{}, component_type: :formula)
      :ok = Record.write_started(formula)
      assert {:ok, %{component_type: :formula}} = Record.get(ctx, formula.id)

      root = Record.new(ctx, "agent:local.aqua", %{}, component_type: :agent, kind: "turn")
      :ok = Record.write_started(root)
      assert {:ok, %{component_type: :agent}} = Record.get(ctx, root.id)
    end
  end

  # ============================================================================
  # Correlation ID Format
  # ============================================================================

  describe "correlation ID format" do
    test "execution_id follows exec_<uuid> format", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})

      assert String.starts_with?(record.id, "exec_")

      uuid_part = String.replace_prefix(record.id, "exec_", "")
      # UUID format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
      assert Regex.match?(
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
               uuid_part
             )
    end

    test "execution IDs are unique", %{ctx: ctx} do
      record1 = Record.new(ctx, "reagent:local.test1:0.1.0", %{})
      record2 = Record.new(ctx, "reagent:local.test2:0.1.0", %{})

      assert record1.id != record2.id
    end
  end

  defmodule RefusingStore do
    @moduledoc false
    @behaviour Arca.ExecutionPayloads.Store

    @impl true
    def put(_ctx, _segments, _bytes), do: {:error, :disk_full}
    @impl true
    def get(_ctx, _segments), do: {:error, :not_found}
    @impl true
    def delete(_ctx, _segments), do: :ok
  end

  describe "a retained input" do
    test "is what the store keeps, while the row's hash and envelope describe the input sent",
         %{ctx: ctx} do
      sent = %{"operation" => "chat", "params" => %{"text" => "hello", "transient" => "ROOM"}}
      kept = %{"operation" => "chat", "params" => %{"text" => "hello"}}

      record = Record.new(ctx, "reagent:local.test:0.1.0", sent, retained_input: kept)
      :ok = Record.write_started(record)

      assert {:ok, _payload, bytes} =
               Arca.ExecutionPayloads.get(Sanctum.Context.actor(ctx), record.id, "input")

      assert Jason.decode!(bytes) == kept

      row = Arca.Repo.get(Arca.Execution, record.id)
      assert row.input_hash == Arca.Execution.hash_input(sent)
      assert %{"keys" => keys} = Jason.decode!(row.input)
      assert "params" in keys
    end
  end

  # A parent row, admitted with its attempt: a child inherits the grant it
  # stores.
  defp parent!(ctx) do
    parent = Record.new(ctx, "formula:local.parent:1.0.0", %{}, component_type: :formula)
    :ok = Record.write_started(parent)
    parent.id
  end
end
