defmodule Sanctum.PolicyLogTest do
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.PolicyLog

  setup do
    # Use a test-specific base path to avoid polluting real config
    test_path = Path.join(System.tmp_dir!(), "policy_log_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    # Checkout the Ecto sandbox to isolate SQLite data between tests
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

    # Create context with request_id
    ctx = %Context{
      user_id: "test_user",
      org_id: nil,
      permissions: MapSet.new([:*]),
      scope: :personal,
      auth_method: :local,
      request_id: "req_#{Ecto.UUID.generate()}",
      session_id: "sess_#{Ecto.UUID.generate()}"
    }

    on_exit(fn ->
      File.rm_rf!(test_path)
      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: ctx, test_path: test_path}
  end

  # ============================================================================
  # Basic Logging
  # ============================================================================

  describe "log/2" do
    test "logs a policy consultation", %{ctx: ctx} do
      result = PolicyLog.log(ctx, %{
        event_type: "policy_consultation",
        component_ref: "registry.cyfr.run/stripe-catalyst:1.0",
        host_policy_snapshot: %{"allowed_domains" => ["api.stripe.com"]},
        decision: "allowed"
      })

      assert result == :ok
    end

    test "includes request_id from context", %{ctx: ctx} do
      :ok = PolicyLog.log(ctx, %{
        event_type: "policy_consultation",
        component_ref: "test:1.0",
        host_policy_snapshot: %{},
        decision: "allowed"
      })

      {:ok, log} = PolicyLog.get(ctx, ctx.request_id)
      assert log["request_id"] == ctx.request_id
    end

    test "includes session_id from context", %{ctx: ctx} do
      :ok = PolicyLog.log(ctx, %{
        event_type: "policy_consultation",
        component_ref: "test:1.0",
        host_policy_snapshot: %{},
        decision: "allowed"
      })

      {:ok, log} = PolicyLog.get(ctx, ctx.request_id)
      assert log["session_id"] == ctx.session_id
    end

    test "includes execution_id when provided", %{ctx: ctx} do
      exec_id = "exec_#{Ecto.UUID.generate()}"

      :ok = PolicyLog.log(ctx, %{
        event_type: "policy_consultation",
        component_ref: "test:1.0",
        execution_id: exec_id,
        host_policy_snapshot: %{},
        decision: "allowed"
      })

      {:ok, log} = PolicyLog.get(ctx, ctx.request_id)
      assert log["execution_id"] == exec_id
    end

    test "captures timestamp", %{ctx: ctx} do
      :ok = PolicyLog.log(ctx, %{
        event_type: "policy_consultation",
        component_ref: "test:1.0",
        host_policy_snapshot: %{},
        decision: "allowed"
      })

      {:ok, log} = PolicyLog.get(ctx, ctx.request_id)
      assert is_binary(log["timestamp"])
      assert {:ok, _, _} = DateTime.from_iso8601(log["timestamp"])
    end
  end

  # ============================================================================
  # Getting Logs
  # ============================================================================

  describe "get/2" do
    test "retrieves a logged policy consultation", %{ctx: ctx} do
      :ok = PolicyLog.log(ctx, %{
        event_type: "policy_consultation",
        component_ref: "registry.cyfr.run/tool:1.0",
        host_policy_snapshot: %{"timeout" => "30s"},
        decision: "allowed"
      })

      {:ok, log} = PolicyLog.get(ctx, ctx.request_id)

      assert log["event_type"] == "policy_consultation"
      assert log["component_ref"] == "registry.cyfr.run/tool:1.0"
      assert log["host_policy_snapshot"]["timeout"] == "30s"
      assert log["decision"] == "allowed"
    end

    test "returns error for non-existent log", %{ctx: ctx} do
      result = PolicyLog.get(ctx, "req_nonexistent")
      assert {:error, :not_found} = result
    end
  end

  describe "get_by_execution/2" do
    test "finds log by execution_id", %{ctx: ctx} do
      exec_id = "exec_#{Ecto.UUID.generate()}"

      :ok = PolicyLog.log(ctx, %{
        event_type: "policy_consultation",
        component_ref: "test:1.0",
        execution_id: exec_id,
        host_policy_snapshot: %{},
        decision: "allowed"
      })

      {:ok, log} = PolicyLog.get_by_execution(ctx, exec_id)
      assert log["execution_id"] == exec_id
    end

    test "returns error when execution not found", %{ctx: ctx} do
      result = PolicyLog.get_by_execution(ctx, "exec_nonexistent")
      assert {:error, :not_found} = result
    end
  end

  # ============================================================================
  # Listing Logs
  # ============================================================================

  describe "list/2" do
    test "returns empty list initially", %{ctx: ctx} do
      {:ok, logs} = PolicyLog.list(ctx)
      assert logs == []
    end

    test "returns logged entries", %{ctx: ctx} do
      :ok = PolicyLog.log(ctx, %{
        event_type: "policy_consultation",
        component_ref: "test:1.0",
        host_policy_snapshot: %{},
        decision: "allowed"
      })

      {:ok, logs} = PolicyLog.list(ctx)
      assert length(logs) == 1
    end

    test "respects limit parameter" do
      test_path = Path.join(System.tmp_dir!(), "policy_log_limit_test_#{:rand.uniform(100_000)}")
      Application.put_env(:arca, :base_path, test_path)

      # Create multiple logs with different request_ids
      for i <- 1..5 do
        ctx = %Context{
          user_id: "test_user",
          permissions: MapSet.new([:*]),
          scope: :personal,
          request_id: "req_#{Ecto.UUID.generate()}"
        }

        :ok = PolicyLog.log(ctx, %{
          event_type: "policy_consultation",
          component_ref: "test:#{i}",
          host_policy_snapshot: %{},
          decision: "allowed"
        })
      end

      ctx = %Context{user_id: "test_user", permissions: MapSet.new([:*]), scope: :personal}
      {:ok, logs} = PolicyLog.list(ctx, limit: 3)

      assert length(logs) == 3

      File.rm_rf!(test_path)
    end

    test "filters by event_type", %{ctx: ctx} do
      # Log allowed
      :ok = PolicyLog.log(ctx, %{
        event_type: "policy_consultation",
        component_ref: "test:1.0",
        host_policy_snapshot: %{},
        decision: "allowed"
      })

      # Log denied with new request_id
      ctx2 = %{ctx | request_id: "req_#{Ecto.UUID.generate()}"}
      :ok = PolicyLog.log(ctx2, %{
        event_type: "policy_denied",
        component_ref: "test:2.0",
        host_policy_snapshot: %{},
        decision: "denied"
      })

      {:ok, denied_logs} = PolicyLog.list(ctx, event_type: "policy_denied")
      assert length(denied_logs) == 1
      assert hd(denied_logs)["event_type"] == "policy_denied"
    end
  end

  # ============================================================================
  # Convenience Functions
  # ============================================================================

  describe "log_allowed/4" do
    test "logs an allowed policy consultation", %{ctx: ctx} do
      :ok = PolicyLog.log_allowed(ctx, "test:1.0", %{"timeout" => "30s"},
        component_type: :catalyst,
        execution_id: "exec_123"
      )

      {:ok, log} = PolicyLog.get(ctx, ctx.request_id)
      assert log["decision"] == "allowed"
      assert log["component_type"] == "catalyst"
      assert log["execution_id"] == "exec_123"
    end
  end

  describe "log_denied/5" do
    test "logs a denied policy consultation", %{ctx: ctx} do
      :ok = PolicyLog.log_denied(ctx, "test:1.0", %{}, "Domain not allowed",
        component_type: :catalyst
      )

      {:ok, log} = PolicyLog.get(ctx, ctx.request_id)
      assert log["decision"] == "denied"
      assert log["decision_reason"] == "Domain not allowed"
      assert log["event_type"] == "policy_denied"
    end
  end

  # ============================================================================
  # Delete
  # ============================================================================

  describe "delete/2" do
    test "deletes a policy log", %{ctx: ctx} do
      :ok = PolicyLog.log(ctx, %{
        event_type: "policy_consultation",
        component_ref: "test:1.0",
        host_policy_snapshot: %{},
        decision: "allowed"
      })

      {:ok, _} = PolicyLog.get(ctx, ctx.request_id)

      :ok = PolicyLog.delete(ctx, ctx.request_id)

      result = PolicyLog.get(ctx, ctx.request_id)
      assert {:error, :not_found} = result
    end
  end
end
