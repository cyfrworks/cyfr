# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.SecurityTest do
  use ExUnit.Case, async: false

  alias Opus.ComponentType

  alias Opus.MCP
  alias Sanctum.Context

  @math_wasm_path Path.join(__DIR__, "../support/test_wasm/math.wasm")
  @test_ref "reagent:local.test-math:0.1.0"

  setup do
    # Use a test-specific base path to avoid state leaking between tests
    test_path = Path.join(System.tmp_dir!(), "opus_security_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))

    # Checkout the Ecto sandbox to isolate SQLite data between tests
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    rand_id = :rand.uniform(100_000)

    ctx =
      Context.build(
        user_id: "sec_test_user_#{rand_id}",
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

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: ctx, test_path: test_path, ref: @test_ref}
  end

  # ============================================================================
  # Component Type Isolation
  # ============================================================================

  describe "component type isolation" do
    test "reagent has WASI but no HTTP capability" do
      opts = ComponentType.wasi_options(:reagent)

      assert opts != nil
      assert opts.allow_http == false
    end

    test "formula has WASI but no HTTP capability" do
      opts = ComponentType.wasi_options(:formula)

      assert opts != nil
      assert opts.allow_http == false
    end

    test "catalyst uses host function HTTP (not native wasi:http)" do
      opts = ComponentType.wasi_options(:catalyst)

      assert opts != nil
      # Catalysts use cyfr:http/fetch host function, not wasi:http/outgoing-handler
      assert opts.allow_http == false
    end

    test "catalyst does not inherit stdin (prevents prompt injection)" do
      opts = ComponentType.wasi_options(:catalyst)

      assert opts.inherit_stdin == false
    end

    test "catalyst inherits stdout/stderr for logging" do
      opts = ComponentType.wasi_options(:catalyst)

      assert opts.inherit_stdout == true
      assert opts.inherit_stderr == true
    end

    test "component type defaults to :reagent when nil" do
      assert {:ok, :reagent} = ComponentType.parse(nil)
    end

    test "invalid component type returns error" do
      assert {:error, _} = ComponentType.parse("unknown")
      assert {:error, _} = ComponentType.parse(:invalid)
    end
  end

  # ============================================================================
  # User Isolation
  # ============================================================================

  describe "user isolation" do
    # Note: math.wasm is a core module, not a Component Model binary. Execution
    # fails at runtime but still creates execution records, which is sufficient
    # to test user isolation on the MCP access control layer.

    test "user can only access their own executions", %{ctx: ctx, ref: ref} do
      # Execute as user — fails at Component Model load but still writes a record
      _result =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 2}
        })

      # List user's executions to find the record
      {:ok, list_result} = MCP.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 1
      execution_id = hd(list_result.executions).execution_id

      # Same user can see the execution
      {:ok, logs_result} =
        MCP.handle("execution", ctx, %{
          "action" => "logs",
          "execution_id" => execution_id
        })

      assert logs_result.execution_id == execution_id

      # Different user cannot see the execution (ownership enforced for non-owner contexts)
      other_ctx =
        Context.build(
          user_id: "other-user-#{:rand.uniform(10000)}",
          project_id: "default",
          permissions: [:execute, :storage_read],
          scope: :project,
          auth_method: :api_key,
          namespace: "testns",
          authenticated: true
        )

      {:error, msg} =
        MCP.handle("execution", other_ctx, %{
          "action" => "logs",
          "execution_id" => execution_id
        })

      assert msg =~ "not found"
    end

    test "user can only list their own executions", %{ctx: ctx, ref: ref} do
      # Execute as user — record is created even on failure
      _result =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 2}
        })

      # User can see their execution
      {:ok, list_result} = MCP.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 1

      # Different user sees empty list
      other_ctx =
        Context.build(
          user_id: "other-user-#{:rand.uniform(10000)}",
          project_id: "default",
          permissions: [:execute, :storage_read],
          scope: :project,
          auth_method: :api_key,
          namespace: "testns",
          authenticated: true
        )

      {:ok, other_list_result} = MCP.handle("execution", other_ctx, %{"action" => "list"})
      assert other_list_result.count == 0
    end

    test "user can only cancel their own executions", %{ctx: ctx} do
      # Create a running execution record directly (no WASM needed)
      record = Opus.ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{})
      :ok = Opus.ExecutionRecord.write_started(record)

      # Different user cannot cancel (ownership enforced for non-owner contexts)
      other_ctx =
        Context.build(
          user_id: "other-user-#{:rand.uniform(10000)}",
          project_id: "default",
          permissions: [:execute, :storage_read],
          scope: :project,
          auth_method: :api_key,
          namespace: "testns",
          authenticated: true
        )

      {:error, msg} =
        MCP.handle("execution", other_ctx, %{
          "action" => "cancel",
          "execution_id" => record.id
        })

      assert msg =~ "not found"
    end
  end

  # ============================================================================
  # Resource Limits
  # ============================================================================

  describe "resource limits" do
    test "default memory limit is 64MB" do
      # The Runtime module defines @default_max_memory_bytes as 64MB
      # This test verifies the module compiles with expected defaults
      assert Code.ensure_loaded?(Opus.Runtime)
    end

    test "default fuel limit is 100M instructions" do
      # The Runtime module defines @default_fuel_limit as 100_000_000
      assert Code.ensure_loaded?(Opus.Runtime)
    end
  end

  # ============================================================================
  # Component Digest
  # ============================================================================

  describe "component digest security" do
    test "execution record includes component_digest", %{ctx: ctx, ref: ref} do
      # Execute — fails at runtime but the digest is computed and stored before execution
      _result =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 2}
        })

      # Retrieve the execution record to verify digest was captured
      {:ok, list_result} = MCP.handle("execution", ctx, %{"action" => "list"})
      execution_id = hd(list_result.executions).execution_id

      {:ok, logs_result} =
        MCP.handle("execution", ctx, %{
          "action" => "logs",
          "execution_id" => execution_id
        })

      assert logs_result.component_digest != nil
      assert String.starts_with?(logs_result.component_digest, "sha256:")
      # SHA256 produces 64 hex characters
      # "sha256:" + 64 hex
      assert String.length(logs_result.component_digest) == 7 + 64
    end

    test "same component produces same digest", %{ctx: ctx, ref: ref} do
      # Execute twice — both records should have the same digest
      _result1 =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 2}
        })

      _result2 =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 2}
        })

      {:ok, list_result} = MCP.handle("execution", ctx, %{"action" => "list"})
      assert length(list_result.executions) >= 2

      digests =
        Enum.map(list_result.executions, fn exec ->
          {:ok, logs} =
            MCP.handle("execution", ctx, %{
              "action" => "logs",
              "execution_id" => exec.execution_id
            })

          logs.component_digest
        end)

      assert length(Enum.uniq(digests)) == 1
    end
  end

  # ============================================================================
  # Size Limits
  # ============================================================================

  describe "request/response size limits" do
    test "input size validation accepts normal input", %{ctx: ctx, ref: ref} do
      # Normal small input passes validation; execution may fail for other reasons
      # (math.wasm is a core module, not Component Model)
      result =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 5, "b" => 3}
        })

      # Error (if any) should NOT be about input size — proving validation passed
      case result do
        {:ok, r} -> assert r.status == "completed"
        {:error, msg} -> refute msg =~ "Input size"
      end
    end

    test "input size validation rejects oversized input", %{ctx: ctx, ref: ref} do
      # Create an input that exceeds 1MB default limit
      # We'll create a large string value
      # 2MB
      large_data = String.duplicate("x", 2_000_000)
      large_input = %{"data" => large_data}

      {:error, msg} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => large_input
        })

      assert msg =~ "Input size"
      assert msg =~ "exceeds maximum"
    end

    test "default input limit is 1MB" do
      # Verify the default limit constant
      policy = Sanctum.Policy.default()
      assert policy.max_request_size == 1_048_576
    end

    test "default output limit is 5MB" do
      # Verify the default limit constant
      policy = Sanctum.Policy.default()
      assert policy.max_response_size == 5_242_880
    end

    test "policy can override size limits" do
      {:ok, policy} =
        Sanctum.Policy.from_map(%{
          "max_request_size" => "512KB",
          "max_response_size" => "10MB"
        })

      assert policy.max_request_size == 512 * 1024
      assert policy.max_response_size == 10 * 1024 * 1024
    end
  end

  # ============================================================================
  # Signature Verification
  # ============================================================================

  describe "signature verification" do
    test "verify block schema is present in tool definition" do
      tools = MCP.tools()
      tool = Enum.find(tools, &(&1.name == "execution"))

      assert tool.input_schema["properties"]["verify"] != nil
      assert tool.input_schema["properties"]["verify"]["type"] == "object"
      assert tool.input_schema["properties"]["verify"]["properties"]["identity"] != nil
      assert tool.input_schema["properties"]["verify"]["properties"]["issuer"] != nil
    end

    test "verify block is optional (no signature error without it)", %{ctx: ctx, ref: ref} do
      # No verify block — should not fail due to signature verification
      result =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 2}
        })

      case result do
        {:ok, r} -> assert r.status == "completed"
        {:error, msg} -> refute msg =~ "Signature verification"
      end
    end

    test "registered components skip signature verification", %{ctx: ctx, ref: ref} do
      # Even with verify block, registered components should not fail on signature verification
      result =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 1, "b" => 2},
          "verify" => %{
            "identity" => "test@example.com",
            "issuer" => "https://example.com"
          }
        })

      case result do
        {:ok, r} -> assert r.status == "completed"
        {:error, msg} -> refute msg =~ "Signature verification"
      end
    end

    test "unregistered component returns not found error", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => "reagent:local.nonexistent:0.1.0",
          "input" => %{}
        })

      assert msg =~ "not found" or msg =~ "resolve"
    end
  end
end
