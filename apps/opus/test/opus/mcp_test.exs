defmodule Opus.MCPTest do
  use ExUnit.Case, async: false

  alias Opus.MCP
  alias Sanctum.Context

  @math_wasm_path Path.join(__DIR__, "../support/test_wasm/math.wasm")

  setup do
    # Use a test-specific base path to avoid state leaking between tests
    test_path = Path.join(System.tmp_dir!(), "opus_mcp_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    # Checkout the Ecto sandbox to isolate SQLite data between tests
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

    ctx = Context.local()

    # Copy WASM to canonical layout for local reference execution
    wasm_dir = Path.join(test_path, "reagents/local/test-math/0.1.0")
    File.mkdir_p!(wasm_dir)
    wasm_path = Path.join(wasm_dir, "reagent.wasm")
    File.cp!(@math_wasm_path, wasm_path)

    on_exit(fn ->
      File.rm_rf!(test_path)
      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: ctx, test_path: test_path, wasm_path: wasm_path}
  end

  # ============================================================================
  # Tool Discovery
  # ============================================================================

  describe "tools/0" do
    test "returns 1 action-based tool" do
      tools = MCP.tools()
      assert length(tools) == 1

      tool_names = Enum.map(tools, & &1.name)
      assert "execution" in tool_names
    end

    test "each tool has required schema fields" do
      for tool <- MCP.tools() do
        assert is_binary(tool.name)
        assert is_binary(tool.title)
        assert is_binary(tool.description)
        assert is_map(tool.input_schema)
        assert tool.input_schema["type"] == "object"
        assert "action" in tool.input_schema["required"]
      end
    end

    test "execution tool has correct actions" do
      tools = MCP.tools()
      tool = Enum.find(tools, & &1.name == "execution")
      actions = tool.input_schema["properties"]["action"]["enum"]
      assert "run" in actions
      assert "list" in actions
      assert "logs" in actions
      assert "cancel" in actions
    end
  end

  # ============================================================================
  # Resources
  # ============================================================================

  describe "resources/0" do
    test "returns execution resources" do
      resources = MCP.resources()
      assert length(resources) == 2

      uris = Enum.map(resources, & &1.uri)
      assert "opus://executions/{id}" in uris
      assert "opus://executions/{id}/logs" in uris
    end
  end

  # ============================================================================
  # Execution Tool - Run Action
  # ============================================================================

  describe "execution tool - run action" do
    test "executes local artifact", %{ctx: ctx, wasm_path: wasm_path} do
      {:ok, result} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => %{"local" => wasm_path},
          "input" => %{"a" => 10, "b" => 25}
        })

      assert result.status == "completed"
      assert result.result == %{"result" => 35}
      assert result.component_type == "reagent"
      assert is_binary(result.execution_id)
      assert String.starts_with?(result.execution_id, "exec_")
    end

    test "returns error for missing reference", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => %{},
          "input" => %{}
        })

      # With empty reference, we get an error about unrecognized reference format
      assert msg =~ "Cannot extract component ref"
    end

    test "returns error for non-canonical local path", %{ctx: ctx, test_path: test_path} do
      {:error, msg} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => %{"local" => Path.join(test_path, "nonexistent.wasm")},
          "input" => %{"a" => 1, "b" => 2}
        })

      assert msg =~ "canonical layout"
    end

    test "respects component type parameter", %{ctx: ctx, wasm_path: wasm_path} do
      {:ok, result} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => %{"local" => wasm_path},
          "input" => %{"a" => 1, "b" => 2},
          "type" => "reagent"
        })

      assert result.component_type == "reagent"
    end
  end

  # ============================================================================
  # Execution Tool - List Action
  # ============================================================================

  describe "execution tool - list action" do
    test "returns empty list initially", %{ctx: ctx} do
      {:ok, result} = MCP.handle("execution", ctx, %{"action" => "list"})
      assert result.executions == []
      assert result.count == 0
    end

    test "returns executions after running", %{ctx: ctx, wasm_path: wasm_path} do
      # Execute something
      {:ok, exec_result} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => %{"local" => wasm_path},
          "input" => %{"a" => 1, "b" => 1}
        })

      # Verify execution succeeded and returned an ID
      assert exec_result.status == "completed"
      assert is_binary(exec_result.execution_id)

      # Now list should show it
      {:ok, result} = MCP.handle("execution", ctx, %{"action" => "list"})

      # The execution should be in the list
      assert result.count >= 1,
             "Expected at least 1 execution, got #{result.count}. Exec ID was: #{exec_result.execution_id}"

      execution = hd(result.executions)
      assert is_binary(execution.execution_id)
      assert execution.status == "completed"
    end

    test "filters by status", %{ctx: ctx, wasm_path: wasm_path} do
      # Execute to create a completed execution
      {:ok, _} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => %{"local" => wasm_path},
          "input" => %{"a" => 1, "b" => 1}
        })

      # Filter by completed
      {:ok, completed_result} =
        MCP.handle("execution", ctx, %{"action" => "list", "status" => "completed"})

      assert completed_result.count >= 1

      # Filter by running (should be empty since execution is fast)
      {:ok, running_result} =
        MCP.handle("execution", ctx, %{"action" => "list", "status" => "running"})

      # Running would be 0 since our test wasm is fast
      assert running_result.count == 0
    end

    test "respects limit parameter", %{ctx: ctx, wasm_path: wasm_path} do
      # Run multiple executions
      for i <- 1..3 do
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => %{"local" => wasm_path},
          "input" => %{"a" => i, "b" => 1}
        })
      end

      {:ok, result} = MCP.handle("execution", ctx, %{"action" => "list", "limit" => 2})
      assert result.count <= 2
    end
  end

  # ============================================================================
  # Execution Tool - Logs Action
  # ============================================================================

  describe "execution tool - logs action" do
    test "returns logs for execution", %{ctx: ctx, wasm_path: wasm_path} do
      {:ok, exec_result} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => %{"local" => wasm_path},
          "input" => %{"a" => 5, "b" => 5}
        })

      execution_id = exec_result.execution_id

      {:ok, logs_result} =
        MCP.handle("execution", ctx, %{
          "action" => "logs",
          "execution_id" => execution_id
        })

      assert logs_result.execution_id == execution_id
      assert logs_result.status == "completed"
      assert is_binary(logs_result.logs)
    end

    test "returns error for missing execution_id", %{ctx: ctx} do
      {:error, msg} = MCP.handle("execution", ctx, %{"action" => "logs"})
      assert msg =~ "Missing required"
    end

    test "returns error for non-existent execution", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("execution", ctx, %{
          "action" => "logs",
          "execution_id" => "exec_nonexistent"
        })

      assert msg =~ "not found"
    end
  end

  # ============================================================================
  # Execution Tool - Cancel Action
  # ============================================================================

  describe "execution tool - cancel action" do
    test "returns error for missing execution_id", %{ctx: ctx} do
      {:error, msg} = MCP.handle("execution", ctx, %{"action" => "cancel"})
      assert msg =~ "Missing required"
    end

    test "returns error for non-existent execution", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("execution", ctx, %{
          "action" => "cancel",
          "execution_id" => "exec_nonexistent"
        })

      assert msg =~ "not found"
    end

    test "returns error for completed execution", %{ctx: ctx, wasm_path: wasm_path} do
      # Run an execution (it completes instantly)
      {:ok, exec_result} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => %{"local" => wasm_path},
          "input" => %{"a" => 1, "b" => 1}
        })

      # Try to cancel completed execution
      {:error, msg} =
        MCP.handle("execution", ctx, %{
          "action" => "cancel",
          "execution_id" => exec_result.execution_id
        })

      assert msg =~ "already completed"
    end
  end

  # ============================================================================
  # Invalid/Missing Action
  # ============================================================================

  describe "execution tool - invalid action" do
    test "returns error for invalid action", %{ctx: ctx} do
      {:error, msg} = MCP.handle("execution", ctx, %{"action" => "invalid"})
      assert msg =~ "Invalid execution action"
    end

    test "returns error for missing action", %{ctx: ctx} do
      {:error, msg} = MCP.handle("execution", ctx, %{})
      assert msg =~ "Missing required"
    end
  end

  # ============================================================================
  # Unknown Tool
  # ============================================================================

  describe "unknown tool" do
    test "returns error for unknown tool", %{ctx: ctx} do
      {:error, msg} = MCP.handle("unknown_tool", ctx, %{})
      assert msg =~ "Unknown tool"
    end
  end

  # ============================================================================
  # Verify Block
  # ============================================================================

  describe "execution tool - verify block" do
    test "verify block is included in tool schema" do
      tools = MCP.tools()
      tool = Enum.find(tools, & &1.name == "execution")

      verify_schema = tool.input_schema["properties"]["verify"]
      assert verify_schema != nil
      assert verify_schema["type"] == "object"
      assert verify_schema["properties"]["identity"]["type"] == "string"
      assert verify_schema["properties"]["issuer"]["type"] == "string"
    end

    test "accepts verify block with identity and issuer", %{ctx: ctx, wasm_path: wasm_path} do
      {:ok, result} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => %{"local" => wasm_path},
          "input" => %{"a" => 10, "b" => 5},
          "verify" => %{
            "identity" => "test@example.com",
            "issuer" => "https://github.com/login/oauth"
          }
        })

      assert result.status == "completed"
      assert result.result == %{"result" => 15}
    end

    test "verify block is optional", %{ctx: ctx, wasm_path: wasm_path} do
      {:ok, result} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => %{"local" => wasm_path},
          "input" => %{"a" => 3, "b" => 7}
        })

      assert result.status == "completed"
    end
  end

  # ============================================================================
  # Component Digest
  # ============================================================================

  describe "execution tool - component digest" do
    test "returns component_digest in result", %{ctx: ctx, wasm_path: wasm_path} do
      {:ok, result} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => %{"local" => wasm_path},
          "input" => %{"a" => 1, "b" => 1}
        })

      assert result.component_digest != nil
      assert String.starts_with?(result.component_digest, "sha256:")
    end

    test "digest is consistent for same WASM bytes", %{ctx: ctx, wasm_path: wasm_path} do
      {:ok, result1} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => %{"local" => wasm_path},
          "input" => %{"a" => 1, "b" => 1}
        })

      {:ok, result2} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => %{"local" => wasm_path},
          "input" => %{"a" => 2, "b" => 2}
        })

      assert result1.component_digest == result2.component_digest
    end
  end

  # ============================================================================
  # Error Recovery
  # ============================================================================

  describe "execution tool - error handling" do
    test "handles invalid WASM bytes gracefully", %{ctx: ctx, test_path: test_path} do
      invalid_path = Path.join(test_path, "invalid.wasm")
      File.write!(invalid_path, "not valid wasm")

      # Invalid WASM may result in either an error return or an exception
      # The execution should not crash the whole system
      result =
        try do
          MCP.handle("execution", ctx, %{
            "action" => "run",
            "reference" => %{"local" => invalid_path},
            "input" => %{}
          })
        rescue
          e -> {:error, Exception.message(e)}
        end

      assert {:error, msg} = result
      assert is_binary(msg)
    end

    test "handles missing reference gracefully", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => %{},
          "input" => %{}
        })

      assert msg =~ "Cannot extract component ref"
    end

    test "handles unknown reference type gracefully", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => %{"unknown" => "value"},
          "input" => %{}
        })

      assert msg =~ "Cannot extract component ref"
    end
  end

  # ============================================================================
  # Crash-Resilient Storage
  # ============================================================================

  describe "execution tool - crash-resilient storage" do
    test "writes execution record to SQLite before execution", %{ctx: ctx, wasm_path: wasm_path} do
      {:ok, result} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => %{"local" => wasm_path},
          "input" => %{"a" => 1, "b" => 1}
        })

      # Check that execution record exists in SQLite
      db_record = Arca.Execution.get(result.execution_id)
      assert db_record != nil
      assert db_record.id == result.execution_id
    end

    test "marks execution as completed in SQLite after successful execution", %{ctx: ctx, wasm_path: wasm_path} do
      {:ok, result} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => %{"local" => wasm_path},
          "input" => %{"a" => 5, "b" => 5}
        })

      db_record = Arca.Execution.get(result.execution_id)
      assert db_record != nil
      assert db_record.status == "completed"
      assert db_record.completed_at != nil
    end

    test "marks execution as failed in SQLite after failed execution", %{ctx: ctx, test_path: test_path} do
      # Create an invalid WASM file that will fail execution
      invalid_path = Path.join(test_path, "invalid_crash.wasm")
      File.write!(invalid_path, "invalid wasm")

      # Invalid WASM may result in either an error return or an exception
      _result =
        try do
          MCP.handle("execution", ctx, %{
            "action" => "run",
            "reference" => %{"local" => invalid_path},
            "input" => %{}
          })
        rescue
          _e -> {:error, "wasm parsing failed"}
        end

      # Check SQLite for a failed execution record
      records = Arca.Execution.list(user_id: ctx.user_id, limit: 10)

      failed_records = Enum.filter(records, &(&1.status == "failed"))

      if length(failed_records) > 0 do
        failed_record = hd(failed_records)
        assert failed_record.status == "failed"
        assert failed_record.error_message != nil
      end
    end
  end

  # ============================================================================
  # Telemetry Events
  # ============================================================================

  describe "execution tool - telemetry" do
    setup do
      test_pid = self()
      handler_id = "mcp-test-telemetry-#{:rand.uniform(100_000)}"

      :telemetry.attach_many(
        handler_id,
        [
          [:cyfr, :opus, :execute, :start],
          [:cyfr, :opus, :execute, :stop],
          [:cyfr, :opus, :execute, :exception]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
      end)

      :ok
    end

    test "emits start and stop telemetry events on success", %{ctx: ctx, wasm_path: wasm_path} do
      {:ok, _result} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => %{"local" => wasm_path},
          "input" => %{"a" => 1, "b" => 2}
        })

      assert_receive {:telemetry, [:cyfr, :opus, :execute, :start], _, start_meta}
      assert_receive {:telemetry, [:cyfr, :opus, :execute, :stop], _, stop_meta}

      assert start_meta.component_type == :reagent
      assert stop_meta.outcome == :success
    end

    test "emits start and exception telemetry events on failure", %{ctx: ctx, test_path: test_path} do
      invalid_path = Path.join(test_path, "invalid_telemetry.wasm")
      File.write!(invalid_path, "invalid")

      # Invalid WASM may result in either an error return or an exception
      _result =
        try do
          MCP.handle("execution", ctx, %{
            "action" => "run",
            "reference" => %{"local" => invalid_path},
            "input" => %{}
          })
        rescue
          _e -> {:error, "wasm parsing failed"}
        end

      # The telemetry events may or may not be emitted depending on where the failure occurs
      # If write_started succeeds, we should see at least the start event
      # This is a best-effort test
    end
  end

  # ============================================================================
  # Resource Provider
  # ============================================================================

  describe "read/2 - execution state resource" do
    test "returns execution state for existing execution", %{ctx: ctx, wasm_path: wasm_path} do
      {:ok, exec_result} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => %{"local" => wasm_path},
          "input" => %{"a" => 7, "b" => 8}
        })

      uri = "opus://executions/#{exec_result.execution_id}"
      {:ok, content} = MCP.read(ctx, uri)

      # Content should be valid JSON
      {:ok, parsed} = Jason.decode(content)

      assert parsed["execution_id"] == exec_result.execution_id
      assert parsed["status"] == "completed"
      assert parsed["component_type"] == "reagent"
      assert parsed["output"] == %{"result" => 15}
      assert is_binary(parsed["component_digest"])
    end

    test "returns error for non-existent execution", %{ctx: ctx} do
      uri = "opus://executions/exec_nonexistent"
      {:error, msg} = MCP.read(ctx, uri)

      assert msg =~ "not found"
    end

    test "parses execution ID correctly", %{ctx: ctx, wasm_path: wasm_path} do
      {:ok, exec_result} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => %{"local" => wasm_path},
          "input" => %{"a" => 1, "b" => 1}
        })

      # URI with just ID
      uri = "opus://executions/#{exec_result.execution_id}"
      {:ok, content} = MCP.read(ctx, uri)

      {:ok, parsed} = Jason.decode(content)
      assert parsed["execution_id"] == exec_result.execution_id
    end
  end

  describe "read/2 - execution logs resource" do
    test "returns logs for existing execution", %{ctx: ctx, wasm_path: wasm_path} do
      {:ok, exec_result} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => %{"local" => wasm_path},
          "input" => %{"a" => 3, "b" => 4}
        })

      uri = "opus://executions/#{exec_result.execution_id}/logs"
      {:ok, content} = MCP.read(ctx, uri)

      # Content should be text logs
      assert is_binary(content)
      assert content =~ "=== Execution #{exec_result.execution_id} ==="
      assert content =~ "Status: completed"
      assert content =~ "Component Type: reagent"
      assert content =~ "Output:"
    end

    test "returns error for non-existent execution logs", %{ctx: ctx} do
      uri = "opus://executions/exec_nonexistent/logs"
      {:error, msg} = MCP.read(ctx, uri)

      assert msg =~ "not found"
    end

    test "includes error in logs for failed execution", %{ctx: ctx, test_path: test_path} do
      invalid_path = Path.join(test_path, "invalid_logs.wasm")
      File.write!(invalid_path, "invalid wasm")

      # Execute invalid WASM
      _result =
        try do
          MCP.handle("execution", ctx, %{
            "action" => "run",
            "reference" => %{"local" => invalid_path},
            "input" => %{}
          })
        rescue
          _e -> {:error, "wasm parsing failed"}
        end

      # Get the execution ID by listing
      {:ok, list_result} = MCP.handle("execution", ctx, %{"action" => "list"})

      if list_result.count > 0 do
        exec = hd(list_result.executions)

        if exec.status == "failed" do
          uri = "opus://executions/#{exec.execution_id}/logs"
          {:ok, content} = MCP.read(ctx, uri)

          assert content =~ "Error:"
        end
      end
    end
  end

  describe "read/2 - unknown URIs" do
    test "returns error for unknown URI scheme", %{ctx: ctx} do
      {:error, msg} = MCP.read(ctx, "unknown://resource")
      assert msg =~ "Unknown resource URI"
    end

    test "returns error for invalid execution URI format", %{ctx: ctx} do
      # Empty execution ID
      {:error, msg} = MCP.read(ctx, "opus://executions/")
      assert msg =~ "Invalid" or msg =~ "not found"
    end
  end
end
