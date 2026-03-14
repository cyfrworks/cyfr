defmodule Opus.RemediationTest do
  use ExUnit.Case, async: false

  alias Opus.Remediation
  alias Sanctum.Context

  setup do
    test_path = Path.join(System.tmp_dir!(), "remediation_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Context.local()

    on_exit(fn ->
      File.rm_rf!(test_path)
      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: ctx, test_path: test_path}
  end

  # ============================================================================
  # analyze/2 - Detection
  # ============================================================================

  describe "analyze/2 - detects setup errors" do
    test "detects 'has no capabilities configured' as setup error", %{ctx: ctx} do
      reason = """
      Catalyst 'catalyst:local.stripe:0.1.0' has no capabilities configured.

      Catalysts require at least one of:
        - allowed_domains (for HTTP access)
        - allowed_paths (for file storage access)

      Configure with:
        cyfr policy set catalyst:local.stripe:0.1.0 allowed_domains '["api.stripe.com"]'
        cyfr policy set catalyst:local.stripe:0.1.0 allowed_paths '["data/"]'
      """

      assert {:setup_required, remediation} = Remediation.analyze(ctx, reason)
      assert remediation["component_ref"] == "catalyst:local.stripe:0.1.0"
      assert remediation["setup_command"] == "cyfr setup catalyst:local.stripe:0.1.0"
      assert is_list(remediation["issues"])
    end

    test "detects 'has no allowed_domains configured' as setup error", %{ctx: ctx} do
      reason = "Catalyst 'catalyst:local.httpbin:0.1.0' has no allowed_domains configured"

      assert {:setup_required, remediation} = Remediation.analyze(ctx, reason)
      assert remediation["component_ref"] == "catalyst:local.httpbin:0.1.0"
    end

    test "detects 'access-denied: not granted to' as setup error", %{ctx: ctx} do
      reason = "access-denied: STRIPE_API_KEY not granted to catalyst:local.stripe:0.1.0"

      assert {:setup_required, remediation} = Remediation.analyze(ctx, reason)
      assert remediation["component_ref"] == "catalyst:local.stripe:0.1.0"
    end

    test "detects 'not granted to component' pattern", %{ctx: ctx} do
      reason = "Secret 'API_KEY' not granted to component 'catalyst:local.example:0.1.0'. Grant with: cyfr secret grant catalyst:local.example:0.1.0 API_KEY"

      assert {:setup_required, remediation} = Remediation.analyze(ctx, reason)
      assert remediation["component_ref"] == "catalyst:local.example:0.1.0"
    end

    test "detects 'Failed to resolve N secret(s)' pattern", %{ctx: ctx} do
      reason = "Failed to resolve 2 secret(s) for catalyst:local.multi:0.1.0: API_KEY, SECRET"

      assert {:setup_required, remediation} = Remediation.analyze(ctx, reason)
      assert remediation["component_ref"] == "catalyst:local.multi:0.1.0"
    end
  end

  # ============================================================================
  # analyze/2 - Non-setup errors
  # ============================================================================

  describe "analyze/2 - non-setup errors" do
    test "returns :not_setup_error for generic execution errors", %{ctx: ctx} do
      assert :not_setup_error == Remediation.analyze(ctx, "Execution timeout after 60000ms")
    end

    test "returns :not_setup_error for JSON parsing errors", %{ctx: ctx} do
      assert :not_setup_error == Remediation.analyze(ctx, "Invalid JSON request")
    end

    test "returns :not_setup_error for tool denied errors", %{ctx: ctx} do
      assert :not_setup_error == Remediation.analyze(ctx, "Tool 'execution.run' not in allowed_tools")
    end

    test "returns :not_setup_error for empty string", %{ctx: ctx} do
      assert :not_setup_error == Remediation.analyze(ctx, "")
    end

    test "handles non-binary reason gracefully" do
      ctx = Context.local()
      assert :not_setup_error == Remediation.analyze(ctx, nil)
    end
  end

  # ============================================================================
  # analyze/2 - Remediation structure
  # ============================================================================

  describe "analyze/2 - remediation structure" do
    test "remediation always has required fields", %{ctx: ctx} do
      reason = "Catalyst 'catalyst:local.test:0.1.0' has no capabilities configured."

      assert {:setup_required, remediation} = Remediation.analyze(ctx, reason)

      assert is_binary(remediation["component_ref"])
      assert is_binary(remediation["setup_command"])
      assert is_binary(remediation["message"])
      assert is_list(remediation["issues"])
    end

    test "remediation includes original error message", %{ctx: ctx} do
      reason = "access-denied: KEY not granted to catalyst:local.x:0.1.0"

      assert {:setup_required, remediation} = Remediation.analyze(ctx, reason)
      assert remediation["message"] == reason
    end

    test "graceful fallback when setup_plan call fails", %{ctx: ctx} do
      # Use a component_ref that doesn't exist — setup_plan will fail
      reason = "Catalyst 'catalyst:local.nonexistent:9.9.9' has no capabilities configured."

      assert {:setup_required, remediation} = Remediation.analyze(ctx, reason)
      assert remediation["component_ref"] == "catalyst:local.nonexistent:9.9.9"
      # Should still return a valid remediation with empty issues
      assert is_list(remediation["issues"])
      assert is_binary(remediation["setup_command"])
    end
  end
end
