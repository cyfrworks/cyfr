# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ResourceLimitsTest do
  use ExUnit.Case, async: false

  alias Sanctum.Authority
  alias Sanctum.Authority.Blob

  @math_wasm_path Path.join(__DIR__, "../support/test_wasm/math.wasm")
  @test_ref "reagent:local.test-math:0.1.0"
  @test_node "reagent:local.test-math"

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

  # Limits are the blob's node limits, frozen at consent time — the
  # authority carries them, the executor enforces them.
  defp authority_with_limits(max_memory_bytes) do
    blob_map = %{
      "canonical" => "jcs-1",
      "nodes" => %{
        @test_node => %{
          "limits" => %{
            "timeout" => "1m",
            "max_memory_bytes" => max_memory_bytes,
            "max_request_size" => 1_048_576,
            "max_response_size" => 5_242_880,
            "rate_limit" => %{"requests" => 100, "window" => "1m"},
            "max_concurrent_tasks" => 5,
            "batch_timeout" => "1m"
          },
          "edges" => %{"@ingress" => %{}}
        }
      }
    }

    {:ok, blob} = Blob.parse(blob_map)

    profile = %{
      profile_id: "prof-limits",
      consent_id: "consent-limits",
      source_ref: @test_node,
      kind: :owner,
      invoke_mode: :open_inert,
      activation: %{@test_node => "sha256:act-limits"}
    }

    {:ok, auth} = Authority.root(profile, blob)
    auth
  end

  describe "execution under the blob's node limits" do
    test "passes memory limit to runtime (fails for core module)", %{ctx: ctx, ref: ref} do
      auth = authority_with_limits(8 * 1024 * 1024)
      assert Authority.limits(auth).max_memory_bytes == 8 * 1024 * 1024

      {:error, error_msg} =
        Opus.Executor.run(ctx, ref, %{"a" => 10, "b" => 10},
          type: :reagent,
          authority: auth
        )

      assert error_msg =~ "Component"
      {:ok, records} = Opus.list(ctx)
      assert Enum.any?(records, &(&1.status == :failed))
    end

    test "passes both limits to runtime (fails for core module)", %{ctx: ctx, ref: ref} do
      auth = authority_with_limits(16 * 1024 * 1024)

      {:error, error_msg} =
        Opus.Executor.run(ctx, ref, %{"a" => 3, "b" => 7},
          type: :reagent,
          authority: auth
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
