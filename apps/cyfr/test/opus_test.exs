# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule OpusTest do
  use ExUnit.Case, async: false
  @moduletag :requires_opus

  alias Sanctum.Consent.Source
  alias Sanctum.Context

  @math_wasm_path Path.join([__DIR__, "support/test_wasm/math.wasm"])
  @test_ref "reagent:local.test-math:0.1.0"
  @test_node "reagent:local.test-math"

  setup do
    test_path = Path.join(System.tmp_dir!(), "opus_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))

    # Checkout the Ecto sandbox to isolate SQLite data between tests
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    start_supervised!(Source.Memory)

    rand_id = :rand.uniform(100_000)

    ctx =
      Context.build(
        user_id: "opus_test_user_#{rand_id}",
        project_id: "default",
        permissions: [:*],
        scope: :project,
        auth_method: :oidc,
        namespace: "testns",
        authenticated: true
      )

    # Register the test WASM in Compendium so string references resolve
    wasm_bytes = File.read!(@math_wasm_path)

    {:ok, component} =
      Compendium.Registry.publish_bytes(ctx, wasm_bytes, %{
        name: "test-math",
        version: "0.1.0",
        type: "reagent",
        description: "Test math component"
      })

    # Every execution roots under a consent: seed the in-memory source
    # with an owner profile whose blob is the policy for the test node.
    :ok =
      Source.Memory.put_profile(ctx, %{
        id: "prof-opus-test",
        kind: :owner,
        source_ref: @test_node,
        label: "default",
        status: :active
      })

    :ok =
      Source.Memory.put_head_consent(ctx, "prof-opus-test", %{
        id: "consent-opus-test",
        revision: 1,
        scope: :versionless,
        pinned_version: "",
        invoke_mode: :open_inert,
        shape_digest: "sha256:shape-opus-test",
        commit_digest: "sha256:commit-opus-test",
        resolved_policy:
          Jason.encode!(%{
            "canonical" => "jcs-1",
            "nodes" => %{
              @test_node => %{
                "limits" => %{
                  "timeout" => "1m",
                  "max_memory_bytes" => 67_108_864,
                  "max_request_size" => 1_048_576,
                  "max_response_size" => 5_242_880,
                  "rate_limit" => %{"requests" => 100, "window" => "1m"},
                  "max_concurrent_tasks" => 5,
                  "batch_timeout" => "1m"
                },
                "edges" => %{"@ingress" => %{}}
              }
            }
          }),
        activation: %{@test_node => component.release_digest},
        vault_refs: []
      })

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: ctx, ref: @test_ref}
  end

  defp run_consented(ctx, input) do
    Opus.run_root(ctx, nil, @test_ref, input, consent_source: Source.Memory)
  end

  describe "run_root/5" do
    test "run creates execution record (core module fails with clear error)", %{ctx: ctx} do
      # math.wasm is a core module, not a Component Model binary.
      # execute_component no longer falls back to core module execution.
      {:error, error_msg} = run_consented(ctx, %{"a" => 5, "b" => 10})

      assert error_msg =~ "Component Model"

      # Failed execution record is still written
      {:ok, records} = Opus.list(ctx)
      assert records != []
      failed = Enum.find(records, &(&1.status == :failed))
      assert failed != nil
    end

    test "refuses an unconsented component instead of guessing", %{ctx: ctx} do
      assert {:error, :no_profile} =
               Opus.run_root(ctx, nil, "reagent:local.nonexistent:0.1.0", %{},
                 consent_source: Source.Memory
               )
    end

    test "returns error for empty reference", %{ctx: ctx} do
      assert {:error, {:invalid_reference, _reason}} =
               Opus.run_root(ctx, nil, "", %{}, consent_source: Source.Memory)
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

    test "retrieves execution after run", %{ctx: ctx} do
      {:error, _} = run_consented(ctx, %{"a" => 1, "b" => 2})

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

    test "returns :not_cancellable for failed execution", %{ctx: ctx} do
      {:error, _} = run_consented(ctx, %{"a" => 1, "b" => 1})

      # Find the failed record via list
      {:ok, records} = Opus.list(ctx)
      record = hd(records)
      assert {:error, :not_cancellable} = Opus.cancel(ctx, record.id)
    end
  end
end
