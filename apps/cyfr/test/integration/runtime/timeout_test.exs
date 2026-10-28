# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.TimeoutTest do
  use ExUnit.Case, async: false

  alias Opus.{Dispatch, Provider}
  alias Prima.Authority
  alias Prima.Authority.Blob

  @test_ref "reagent:local.test-math:0.1.0"
  @spin_node "reagent:local.spin"
  @spin_ref "reagent:local.spin:0.1.0"
  # A reagent whose compute never returns: only the run's own timeout ends it.
  @spin_wasm Path.expand("../../../../locus/test/support/runtime/test_wasm/spin.wasm", __DIR__)

  setup tags do
    # Use a test-specific base path to avoid state leaking between tests
    test_path = Path.join(System.tmp_dir!(), "runtime_timeout_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    # Every execution roots under a profile's consent: bootstrap mints one
    # through the production DB source, and the loader reads it back.

    # Checkout the Ecto sandbox to isolate SQLite data between tests
    Cyfr.Test.Sandbox.setup!(tags)

    ctx = Sanctum.TestContext.local(:api)

    # Plant the test WASM in a private seed so bootstrap can mint it.
    Cyfr.Test.SeedBundle.isolate!()
    wasm_bytes = Cyfr.Test.Guests.wasm(:reagent)

    {:ok, _component} =
      Arca.Test.UnitFixtures.ship_bytes!(ctx, wasm_bytes, %{
        name: "test-math",
        version: "0.1.0",
        type: "reagent",
        description: "Test math component"
      })

    {:ok, _spin} =
      Arca.Test.UnitFixtures.ship_bytes!(ctx, File.read!(@spin_wasm), %{
        name: "spin",
        version: "0.1.0",
        type: "reagent",
        description: "A reagent that never returns"
      })

    {:ok, _} = Sanctum.Consent.Bootstrap.run(ctx)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    Sanctum.TestContext.ready!(ctx.athanor_id)
    {:ok, ctx: ctx, test_path: test_path, ref: @test_ref}
  end

  # The spin reagent under a consent whose node limit is `timeout`, built as
  # resource_limits_test.exs builds its own.
  defp spin_authority(timeout) do
    {:ok, blob} =
      Blob.parse(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          @spin_node => %{
            "limits" => %{
              "timeout" => timeout,
              "max_memory_bytes" => 64 * 1024 * 1024,
              "max_request_size" => 1_048_576,
              "max_response_size" => 5_242_880,
              "rate_limit" => %{"requests" => 100, "window" => "1m"},
              "max_concurrent_tasks" => 5,
              "batch_timeout" => "1m"
            },
            "edges" => %{"@ingress" => %{}}
          }
        }
      })

    profile = %{
      profile_id: "prof-spin",
      consent_id: "consent-spin",
      source_ref: @spin_node,
      kind: :owner,
      invoke_mode: :open_inert,
      activation: %{@spin_node => "sha256:act-spin"}
    }

    {:ok, auth} =
      Authority.root(profile, blob, ceiling: Sanctum.Policy.Ceiling.platform_ceiling())

    auth
  end

  describe "timeout enforcement" do
    test "a dispatched run accepts the timeout_ms option", %{ctx: ctx, ref: ref} do
      {:ok, authority} = Opus.authority_for(ctx, :default, ref)

      assert {:ok, %{status: :completed}} =
               Dispatch.run(ctx, ref, %{"a" => 10, "b" => 20},
                 timeout_ms: 5000,
                 authority: authority
               )
    end

    test "a run past its consented timeout is ended at it and recorded as failed", %{ctx: ctx} do
      auth = spin_authority("1s")
      assert Authority.limits(auth).timeout == "1s"

      {micros, result} =
        :timer.tc(fn ->
          Dispatch.run(ctx, @spin_ref, %{"a" => 1, "b" => 2}, type: "reagent", authority: auth)
        end)

      assert {:error, _reason} = result
      # The 1 s limit ends the run. The bound is loose enough for a loaded host
      # and far below any run the limit failed to end.
      assert micros < 5_000_000

      {:ok, records} = Opus.Record.list(ctx)

      assert [%{status: :failed, error: error}] =
               Enum.filter(records, &(&1.reference == @spin_ref))

      assert error =~ "timeout"
    end
  end

  describe "timeout edge cases" do
    test "multiple executions create independent records", %{ctx: ctx, ref: ref} do
      # Run multiple executions — each creates a record
      for _i <- 1..3 do
        _result =
          Provider.handle("execution", ctx, %{
            "action" => "run",
            "reference" => ref,
            "input" => %{"a" => 1, "b" => 1}
          })
      end

      {:ok, list_result} = Provider.handle("execution", ctx, %{"action" => "list"})
      assert list_result.count >= 3
    end
  end
end
