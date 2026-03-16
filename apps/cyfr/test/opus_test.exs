defmodule OpusTest do
  use ExUnit.Case, async: false
  @moduletag :requires_opus

  alias Sanctum.Context

  @math_wasm_path Path.join([__DIR__, "support/test_wasm/math.wasm"])
  @test_ref "reagent:local.test-math:0.1.0"

  setup do
    test_path = Path.join(System.tmp_dir!(), "opus_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))

    # Checkout the Ecto sandbox to isolate SQLite data between tests
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    rand_id = :rand.uniform(100_000)

    ctx =
      Context.build(
        user_id: "opus_test_user_#{rand_id}",
        project_id: "default",
        permissions: [:*],
        scope: :project,
        auth_method: :local,
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

    {:ok, ctx: ctx, ref: @test_ref}
  end

  describe "run/4" do
    test "run creates execution record (core module fails with clear error)", %{
      ctx: ctx,
      ref: ref
    } do
      # math.wasm is a core module, not a Component Model binary.
      # execute_component no longer falls back to core module execution.
      {:error, error_msg} = Opus.run(ctx, ref, %{"a" => 5, "b" => 10})

      assert error_msg =~ "Component Model"

      # Failed execution record is still written
      {:ok, records} = Opus.list(ctx)
      assert records != []
      failed = Enum.find(records, &(&1.status == :failed))
      assert failed != nil
    end

    test "returns error for unregistered component", %{ctx: ctx} do
      {:error, msg} = Opus.run(ctx, "reagent:local.nonexistent:0.1.0", %{})
      assert msg =~ "not found" or msg =~ "resolve"
    end

    test "returns error for empty reference", %{ctx: ctx} do
      {:error, msg} = Opus.run(ctx, "", %{})
      assert msg =~ "cannot be empty"
    end
  end

  describe "list/2" do
    test "lists execution records", %{ctx: ctx} do
      {:ok, records} = Opus.list(ctx)
      assert is_list(records)
    end

    test "returns empty list initially", %{ctx: ctx} do
      {:ok, records} = Opus.list(ctx)
      assert records == []
    end
  end

  describe "get/2" do
    test "returns :not_found for non-existent execution", %{ctx: ctx} do
      assert {:error, :not_found} = Opus.get(ctx, "exec_nonexistent")
    end

    test "retrieves execution after run", %{ctx: ctx, ref: ref} do
      {:error, _} = Opus.run(ctx, ref, %{"a" => 1, "b" => 2})

      # Execution record is written even on failure; find it via list
      {:ok, records} = Opus.list(ctx)
      assert records != []
      record = hd(records)
      {:ok, fetched} = Opus.get(ctx, record.id)
      assert fetched.id == record.id
      assert fetched.status == :failed
    end
  end

  describe "cancel/2" do
    test "returns :not_found for non-existent execution", %{ctx: ctx} do
      assert {:error, :not_found} = Opus.cancel(ctx, "exec_nonexistent")
    end

    test "returns :not_cancellable for failed execution", %{ctx: ctx, ref: ref} do
      {:error, _} = Opus.run(ctx, ref, %{"a" => 1, "b" => 1})

      # Find the failed record via list
      {:ok, records} = Opus.list(ctx)
      record = hd(records)
      assert {:error, :not_cancellable} = Opus.cancel(ctx, record.id)
    end
  end
end
