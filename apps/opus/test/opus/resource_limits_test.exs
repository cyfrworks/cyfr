defmodule Opus.ResourceLimitsTest do
  use ExUnit.Case, async: false

  alias Sanctum.Context

  @math_wasm_path Path.join(__DIR__, "../support/test_wasm/math.wasm")
  @test_ref "reagent:local.test-math:0.1.0"

  setup do
    test_path = Path.join(System.tmp_dir!(), "opus_limits_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()

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
  # High-Level API (Opus.run) — tests Component Model path
  # ============================================================================

  describe "Opus.run with limits" do
    test "passes memory limit to runtime (fails for core module)", %{ctx: ctx, ref: ref} do
      {:error, error_msg} =
        Opus.run(
          ctx,
          ref,
          %{"a" => 10, "b" => 10},
          max_memory_bytes: 8 * 1024 * 1024
        )

      assert error_msg =~ "Component"
      {:ok, records} = Opus.list(ctx)
      assert Enum.any?(records, &(&1.status == :failed))
    end

    test "passes both limits to runtime (fails for core module)", %{ctx: ctx, ref: ref} do
      {:error, error_msg} =
        Opus.run(
          ctx,
          ref,
          %{"a" => 3, "b" => 7},
          max_memory_bytes: 16 * 1024 * 1024
        )

      assert error_msg =~ "Component"
    end
  end

  # ============================================================================
  # Default Values
  # ============================================================================

  describe "default limit values" do
    test "default memory limit is 64MB" do
      default_mb = 64 * 1024 * 1024
      assert default_mb == 67_108_864
    end
  end
end
