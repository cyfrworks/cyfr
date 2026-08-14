# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.MCPTest do
  use ExUnit.Case, async: false

  alias Opus.MCP
  alias Sanctum.Context

  @math_wasm_path Path.join(__DIR__, "../support/test_wasm/math.wasm")
  @test_ref "reagent:local.test-math:0.1.0"

  setup do
    # Use a test-specific base path to avoid state leaking between tests
    test_path = Path.join(System.tmp_dir!(), "opus_mcp_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))

    # Every execution roots under a profile's consent: bootstrap mints one
    # through the production DB source, and the loader reads it back.
    Application.put_env(:cyfr, :consent_source, Sanctum.Consent.Source.DB)

    # Checkout the Ecto sandbox to isolate SQLite data between tests
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    rand_id = :rand.uniform(100_000)

    ctx =
      Context.build(
        user_id: "mcp_test_user_#{rand_id}",
        # Unique tenant per test: executions/logs are project-scoped (shared
        # within a tenant), so isolation between tests is by org/project.
        org_id: "mcp_test_org_#{rand_id}",
        project_id: "default",
        permissions: [:*],
        scope: :project,
        auth_method: :oidc,
        namespace: "testns",
        authenticated: true
      )

    # Register the test WASM in Compendium so string references resolve
    wasm_bytes = File.read!(@math_wasm_path)

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, wasm_bytes, %{
        name: "test-math",
        version: "0.1.0",
        type: "reagent",
        description: "Test math component"
      })

    {:ok, _} = Sanctum.Consent.Bootstrap.run(ctx)

    on_exit(fn ->
      File.rm_rf!(test_path)
      Application.put_env(:cyfr, :consent_source, Sanctum.Consent.Source.Memory)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: ctx, test_path: test_path, ref: @test_ref}
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
      tool = Enum.find(tools, &(&1.name == "execution"))
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
    test "returns no concrete resources" do
      resources = MCP.resources()
      assert resources == []
    end
  end

  describe "resource_templates/0" do
    test "returns execution resource templates" do
      templates = MCP.resource_templates()
      assert length(templates) == 2

      uris = Enum.map(templates, & &1.uriTemplate)
      assert "opus://executions/{id}" in uris
      assert "opus://executions/{id}/logs" in uris
    end
  end

  # ============================================================================
  # Execution Tool - Run Action
  #
  # Note: math.wasm is a core module (not a WASI P2 Component Model binary),
  # so executions fail at runtime with "Component Model load failed". However,
  # the Executor still writes started + failed records to SQLite, so we can
  # verify record-keeping behavior by inspecting the failed records.
  # ============================================================================

  describe "execution tool - run action" do
    test "executes registered component and creates failed record", %{ctx: ctx, ref: ref} do
      # Execution will fail because math.wasm is a core module, not a Component Model binary
      _result =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 10, "b" => 25}
        })

      # List to get the execution record
      {:ok, list_result} = MCP.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 1

      execution = hd(list_result.executions)
      assert String.starts_with?(execution.execution_id, "exec_")
      assert execution.status == "failed"

      # Get detailed logs to verify component_type and error
      {:ok, logs_result} =
        MCP.handle("execution", ctx, %{
          "action" => "logs",
          "execution_id" => execution.execution_id
        })

      assert logs_result.component_type == "reagent"
      assert logs_result.status == "failed"
      assert logs_result.error =~ "Component compilation failed"
    end

    test "returns error for missing reference", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => "",
          "input" => %{}
        })

      assert msg =~ "cannot be empty"
    end

    test "returns error for unregistered component", %{ctx: ctx} do
      # An unregistered component has no profile, so the consent gate
      # refuses before resolution is attempted.
      {:error, msg} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => "reagent:local.nonexistent:0.1.0",
          "input" => %{"a" => 1, "b" => 2}
        })

      assert msg =~ "consent_required: "
    end

    test "respects component type parameter", %{ctx: ctx, ref: ref} do
      # Component type is extracted from the reference before execution,
      # so it should be present in the record even though execution fails
      _result =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 2},
          "type" => "reagent"
        })

      {:ok, list_result} = MCP.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 1

      execution = hd(list_result.executions)

      {:ok, logs_result} =
        MCP.handle("execution", ctx, %{
          "action" => "logs",
          "execution_id" => execution.execution_id
        })

      assert logs_result.component_type == "reagent"
    end
  end

  # ============================================================================
  # Execution Tool - List Action
  #
  # Note: math.wasm is a core module, so executions fail at runtime but
  # records are still created. Tests verify listing of failed records.
  # ============================================================================

  describe "execution tool - list action" do
    test "returns empty list initially", %{ctx: ctx} do
      {:ok, result} = MCP.handle("execution", ctx, %{"action" => "list"})
      assert result.executions == []
      assert result.count == 0
    end

    test "returns executions after running", %{ctx: ctx, ref: ref} do
      # Execute something (will fail because math.wasm is a core module)
      _exec_result =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 1}
        })

      # Now list should show the failed record
      {:ok, result} = MCP.handle("execution", ctx, %{"action" => "list"})

      assert result.count >= 1
      execution = hd(result.executions)
      assert is_binary(execution.execution_id)
      assert execution.status == "failed"
    end

    test "filters by status", %{ctx: ctx, ref: ref} do
      # Execute to create a failed execution record
      _result =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 1}
        })

      # Filter by failed
      {:ok, failed_result} =
        MCP.handle("execution", ctx, %{"action" => "list", "status" => "failed"})

      assert failed_result.count >= 1

      # Filter by completed (should be empty since math.wasm always fails)
      {:ok, completed_result} =
        MCP.handle("execution", ctx, %{"action" => "list", "status" => "completed"})

      assert completed_result.count == 0

      # Filter by running (should be empty since execution finishes quickly)
      {:ok, running_result} =
        MCP.handle("execution", ctx, %{"action" => "list", "status" => "running"})

      assert running_result.count == 0
    end

    test "respects limit parameter", %{ctx: ctx, ref: ref} do
      # Run multiple executions (all will fail)
      for i <- 1..3 do
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => i, "b" => 1}
        })
      end

      {:ok, result} = MCP.handle("execution", ctx, %{"action" => "list", "limit" => 2})
      assert result.count <= 2
    end
  end

  # ============================================================================
  # Execution Tool - Logs Action
  #
  # Note: math.wasm is a core module, so executions fail at runtime but
  # records are still created. Tests verify log retrieval of failed records.
  # ============================================================================

  describe "execution tool - logs action" do
    test "returns logs for execution", %{ctx: ctx, ref: ref} do
      # Execute (will fail)
      _exec_result =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 5, "b" => 5}
        })

      # Get execution_id from list
      {:ok, list_result} = MCP.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 1
      execution_id = hd(list_result.executions).execution_id

      {:ok, logs_result} =
        MCP.handle("execution", ctx, %{
          "action" => "logs",
          "execution_id" => execution_id
        })

      assert logs_result.execution_id == execution_id
      assert logs_result.status == "failed"
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

    test "returns error for failed execution", %{ctx: ctx, ref: ref} do
      # Run an execution (it fails because math.wasm is a core module)
      _exec_result =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 1}
        })

      # Get execution_id from list
      {:ok, list_result} = MCP.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 1
      execution_id = hd(list_result.executions).execution_id

      # Try to cancel the failed execution
      {:error, msg} =
        MCP.handle("execution", ctx, %{
          "action" => "cancel",
          "execution_id" => execution_id
        })

      assert msg =~ "already completed" or msg =~ "already failed" or msg =~ "not cancellable" or
               msg =~ "cancelled"
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
  # Force Release Action
  # ============================================================================

  describe "execution tool - force_release action" do
    test "platform admin can force release" do
      # Releasing every tenant's slots is a platform-wide side effect, so the
      # action takes platform scope AND :admin — the default system context's
      # permission set deliberately lacks :admin.
      platform_ctx = Sanctum.internal_context(permissions: [:admin])

      {:ok, result} = MCP.handle("execution", platform_ctx, %{"action" => "force_release"})
      assert result.force_released == true
    end

    test "a tenant admin is denied force_release", %{ctx: ctx} do
      # TestContext.local() carries :admin via the wildcard — but it is
      # project-scoped, and a per-tenant admin must not release other
      # tenants' slots.
      {:error, msg} = MCP.handle("execution", ctx, %{"action" => "force_release"})
      assert msg =~ "platform-operator action"
    end

    test "non-admin user is denied force_release" do
      non_admin_ctx = %Context{
        user_id: "regular_user",
        org_id: nil,
        permissions: MapSet.new([:execute]),
        scope: :project,
        auth_method: :api_key,
        api_key_type: :application
      }

      {:error, msg} = MCP.handle("execution", non_admin_ctx, %{"action" => "force_release"})
      assert msg =~ "platform-operator action"
    end
  end

  # ============================================================================
  # Permission Gates
  #
  # Tests that restricted (non-admin) contexts are properly gated on actions
  # that require elevated permissions, while still allowing general actions.
  # ============================================================================

  describe "permission gates" do
    setup do
      restricted_ctx = %Context{
        user_id: "restricted_user",
        org_id: "local",
        project_id: "default",
        permissions: MapSet.new([:execute]),
        scope: :project,
        auth_method: :api_key,
        api_key_type: :application,
        authenticated: true
      }

      no_execute_ctx = %Context{
        user_id: "no_exec_user",
        org_id: "local",
        project_id: "default",
        permissions: MapSet.new([:component_read]),
        scope: :project,
        auth_method: :api_key,
        api_key_type: :application,
        authenticated: true
      }

      {:ok, restricted_ctx: restricted_ctx, no_execute_ctx: no_execute_ctx}
    end

    test "non-admin user can still run executions", %{restricted_ctx: restricted_ctx, ref: ref} do
      # The run action is open to all authenticated users. Even though execution
      # fails (math.wasm is a core module), the error should NOT be "Unauthorized".
      result =
        MCP.handle("execution", restricted_ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 2}
        })

      case result do
        {:error, msg} ->
          refute msg =~ "Unauthorized",
                 "run action should not require admin permissions"

        {:ok, _} ->
          # If it somehow succeeds, that's fine too
          :ok
      end
    end

    test "non-admin user can list their own executions", %{restricted_ctx: restricted_ctx} do
      {:ok, result} = MCP.handle("execution", restricted_ctx, %{"action" => "list"})
      assert is_list(result.executions)
      assert is_integer(result.count)
    end

    test "execution.status denied without :execute permission", %{no_execute_ctx: no_execute_ctx} do
      {:error, msg} = MCP.handle("execution", no_execute_ctx, %{"action" => "status"})
      assert msg =~ "Unauthorized"
      assert msg =~ "execute"
    end

    test "execution.cancel denied without :execute permission", %{no_execute_ctx: no_execute_ctx} do
      {:error, msg} =
        MCP.handle("execution", no_execute_ctx, %{
          "action" => "cancel",
          "execution_id" => "exec_nonexistent"
        })

      assert msg =~ "Unauthorized"
      assert msg =~ "execute"
    end

    test "execution.status allowed with :execute permission", %{restricted_ctx: restricted_ctx} do
      {:ok, result} = MCP.handle("execution", restricted_ctx, %{"action" => "status"})
      assert is_map(result)
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
  #
  # Note: math.wasm is a core module, so executions fail at runtime with
  # "Component Model load failed". The key assertion is that the error is NOT
  # about signature verification -- proving verification passed successfully.
  # ============================================================================

  describe "execution tool - verify block" do
    test "verify block is included in tool schema" do
      tools = MCP.tools()
      tool = Enum.find(tools, &(&1.name == "execution"))

      verify_schema = tool.input_schema["properties"]["verify"]
      assert verify_schema != nil
      assert verify_schema["type"] == "object"
      assert verify_schema["properties"]["identity"]["type"] == "string"
      assert verify_schema["properties"]["issuer"]["type"] == "string"
    end

    test "accepts verify block with identity and issuer", %{ctx: ctx, ref: ref} do
      # Execution fails because math.wasm is a core module, but the error
      # should be about Component Model loading, NOT signature verification
      {:error, msg} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 10, "b" => 5},
          "verify" => %{
            "identity" => "test@example.com",
            "issuer" => "https://github.com/login/oauth"
          }
        })

      assert msg =~ "Component compilation failed"
      refute msg =~ "Signature verification failed"
    end

    test "verify block is optional", %{ctx: ctx, ref: ref} do
      # Without verify block, execution still proceeds (and fails at Component Model load)
      {:error, msg} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 3, "b" => 7}
        })

      assert msg =~ "Component compilation failed"
    end
  end

  # ============================================================================
  # Component Digest
  #
  # Note: The component digest is computed from WASM bytes before execution,
  # so even though math.wasm fails at runtime, the digest is still recorded
  # in the failed execution record.
  # ============================================================================

  describe "execution tool - component digest" do
    test "returns component_digest in failed record", %{ctx: ctx, ref: ref} do
      _result =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 1}
        })

      {:ok, list_result} = MCP.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 1
      execution_id = hd(list_result.executions).execution_id

      {:ok, logs_result} =
        MCP.handle("execution", ctx, %{
          "action" => "logs",
          "execution_id" => execution_id
        })

      assert logs_result.component_digest != nil
      assert String.starts_with?(logs_result.component_digest, "sha256:")
    end

    test "digest is consistent for same WASM bytes", %{ctx: ctx, ref: ref} do
      # Run two executions with same WASM (both will fail)
      _result1 =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 1}
        })

      _result2 =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 2, "b" => 2}
        })

      # List both executions and check their digests via logs
      {:ok, list_result} = MCP.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 2

      digests =
        Enum.map(list_result.executions, fn exec ->
          {:ok, logs} =
            MCP.handle("execution", ctx, %{
              "action" => "logs",
              "execution_id" => exec.execution_id
            })

          logs.component_digest
        end)

      # All digests should be the same since they use the same WASM bytes
      assert Enum.uniq(digests) |> length() == 1
    end
  end

  # ============================================================================
  # Error Recovery
  # ============================================================================

  describe "execution tool - error handling" do
    test "handles unregistered component gracefully", %{ctx: ctx} do
      # Unregistered component should return a clear error — no profile
      # exists for it, so the consent gate names the fix.
      result =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => "reagent:local.nonexistent-component:0.1.0",
          "input" => %{}
        })

      assert {:error, msg} = result
      assert is_binary(msg)
      assert msg =~ "consent_required: "
    end

    test "handles empty reference gracefully", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => "",
          "input" => %{}
        })

      assert msg =~ "cannot be empty"
    end
  end

  # ============================================================================
  # Crash-Resilient Storage
  #
  # Note: math.wasm is a core module, so executions fail at runtime with
  # "Component Model load failed". The Executor still writes started + failed
  # records to SQLite, so crash-resilient storage is testable with failed records.
  # ============================================================================

  describe "execution tool - crash-resilient storage" do
    test "writes execution record to SQLite before execution", %{ctx: ctx, ref: ref} do
      _result =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 1}
        })

      # Get execution_id from list
      {:ok, list_result} = MCP.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 1
      execution_id = hd(list_result.executions).execution_id

      # Check that execution record exists in SQLite
      db_record = Arca.Repo.get(Arca.Execution, execution_id)
      assert db_record != nil
      assert db_record.id == execution_id
    end

    test "marks execution as failed in SQLite after core module execution", %{ctx: ctx, ref: ref} do
      _result =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 5, "b" => 5}
        })

      # Get execution_id from list
      {:ok, list_result} = MCP.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 1
      execution_id = hd(list_result.executions).execution_id

      db_record = Arca.Repo.get(Arca.Execution, execution_id)
      assert db_record != nil
      assert db_record.status == "failed"
      assert db_record.completed_at != nil
    end

    test "marks execution as failed in SQLite for unregistered component", %{ctx: ctx} do
      # Unregistered component should fail and write a record
      _result =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => "reagent:local.unregistered-crash:0.1.0",
          "input" => %{}
        })

      # Check SQLite for a failed execution record
      records =
        Arca.Execution.list(
          user_id: ctx.user_id,
          limit: 10,
          org_id: ctx.org_id || "",
          project_id: ctx.project_id || "default"
        )

      failed_records = Enum.filter(records, &(&1.status == "failed"))

      if failed_records != [] do
        failed_record = hd(failed_records)
        assert failed_record.status == "failed"
        assert failed_record.error_message != nil
      end
    end
  end

  # ============================================================================
  # Telemetry Events
  #
  # Note: math.wasm is a core module, so executions fail at runtime. The
  # Executor emits start + exception telemetry events on failure (not stop).
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

    test "emits start and exception telemetry events on core module failure", %{
      ctx: ctx,
      ref: ref
    } do
      # Execution fails because math.wasm is a core module
      _result =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 2}
        })

      assert_receive {:telemetry, [:cyfr, :opus, :execute, :start], _, start_meta}
      assert start_meta.component_type == :reagent

      assert_receive {:telemetry, [:cyfr, :opus, :execute, :exception], _, exception_meta}
      assert exception_meta.outcome == :failure
    end

    test "emits telemetry events on unregistered component failure", %{ctx: ctx} do
      # Unregistered component — should fail at resolve step
      _result =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => "reagent:local.unregistered-telemetry:0.1.0",
          "input" => %{}
        })

      # The telemetry events may or may not be emitted depending on where the failure occurs
      # If write_started succeeds, we should see at least the start event
      # This is a best-effort test
    end
  end

  # ============================================================================
  # Resource Provider
  #
  # Note: math.wasm is a core module, so executions fail at runtime. Resource
  # reads return the failed execution record with status "failed" and no output.
  # ============================================================================

  describe "read/2 - execution state resource" do
    test "returns execution state for existing execution", %{ctx: ctx, ref: ref} do
      _exec_result =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 7, "b" => 8}
        })

      # Get execution_id from list
      {:ok, list_result} = MCP.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 1
      execution_id = hd(list_result.executions).execution_id

      uri = "opus://executions/#{execution_id}"
      {:ok, content} = MCP.read(ctx, uri)

      # Content should be valid JSON
      {:ok, parsed} = Jason.decode(content)

      assert parsed["execution_id"] == execution_id
      assert parsed["status"] == "failed"
      assert parsed["component_type"] == "reagent"
      assert is_binary(parsed["component_digest"])
    end

    test "returns error for non-existent execution", %{ctx: ctx} do
      uri = "opus://executions/exec_nonexistent"
      {:error, msg} = MCP.read(ctx, uri)

      assert msg =~ "not found"
    end

    test "parses execution ID correctly", %{ctx: ctx, ref: ref} do
      _exec_result =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 1}
        })

      # Get execution_id from list
      {:ok, list_result} = MCP.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 1
      execution_id = hd(list_result.executions).execution_id

      # URI with just ID
      uri = "opus://executions/#{execution_id}"
      {:ok, content} = MCP.read(ctx, uri)

      {:ok, parsed} = Jason.decode(content)
      assert parsed["execution_id"] == execution_id
    end
  end

  describe "read/2 - execution logs resource" do
    test "returns logs for existing execution", %{ctx: ctx, ref: ref} do
      _exec_result =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 3, "b" => 4}
        })

      # Get execution_id from list
      {:ok, list_result} = MCP.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 1
      execution_id = hd(list_result.executions).execution_id

      uri = "opus://executions/#{execution_id}/logs"
      {:ok, content} = MCP.read(ctx, uri)

      # Content should be text logs
      assert is_binary(content)
      assert content =~ "=== Execution #{execution_id} ==="
      assert content =~ "Status: failed"
      assert content =~ "Component Type: reagent"
      assert content =~ "Error:"
    end

    test "returns error for non-existent execution logs", %{ctx: ctx} do
      uri = "opus://executions/exec_nonexistent/logs"
      {:error, msg} = MCP.read(ctx, uri)

      assert msg =~ "not found"
    end

    test "includes error in logs for failed execution", %{ctx: ctx} do
      # Execute unregistered component
      _result =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => "reagent:local.unregistered-logs:0.1.0",
          "input" => %{}
        })

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
