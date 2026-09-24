# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.MemoryBoundTest do
  @moduledoc """
  The engine bounds a guest's memory by its consent, in the runner, before
  the runner's own memory bound is reached, and the runner stays clean for
  its athanor's next run: a guest declaring a second linear memory, or a
  table past the bound, is refused as a `resource_limit` in the run's row
  and the caller's result; a guest that grows its memory and its table
  reaches the consented total and the table bound exactly and is refused
  past them, and completes. Each run of the athanor here runs in the one
  runner the first took, which the pool reuses only after a clean
  completion, and no runner is tainted.

  The guests are `test_wasm/hostile/` of Opus's suite, run by the Opus
  service over the suite's wire; what happened is read from the rows, the
  results and the status the service answers.
  """

  use ExUnit.Case, async: false

  import Prima.Test.Wait

  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Cyfr.Test.{OpusService, TwoServices}

  @moduletag timeout: 120_000

  @dir Path.expand("../../../../opus/test/support/test_wasm/hostile", __DIR__)
  @mib 1024 * 1024

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)
    TwoServices.watch!()

    run_dir = Path.join(System.tmp_dir!(), "memory_bound_#{System.unique_integer([:positive])}")
    previous = Application.fetch_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, run_dir)

    unique = System.unique_integer([:positive])

    # An athanor of the test's own, so the runner its first run takes is the
    # only one idle for it.
    {:ok, athanor} =
      Sanctum.Tenancy.Athanors.create_for_operator(%{
        kind: "group",
        name: "Memory bound #{unique}",
        slug: "memory-bound-#{unique}",
        created_by: "system"
      })

    ctx = %{Sanctum.TestContext.local() | athanor_id: athanor.id}

    on_exit(fn ->
      Prima.Slots.forgive_unreaped(Cyfr.Execution.Slots, ctx.athanor_id)
      File.rm_rf!(run_dir)

      case previous do
        {:ok, value} -> Application.put_env(:arca, :base_path, value)
        :error -> Application.delete_env(:arca, :base_path)
      end
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()

    for name <- ["extra_memory", "wide_table", "grower"] do
      {:ok, _component} =
        Compendium.Registry.publish_bytes(ctx, File.read!(Path.join(@dir, "#{name}.wasm")), %{
          name: node_name(name),
          version: "0.1.0",
          type: "reagent",
          description: "A guest that pushes against the engine's bounds"
        })
    end

    {:ok, ctx: ctx}
  end

  defp node_name(name), do: "hostile-" <> String.replace(name, "_", "-")
  defp node_ref(name), do: "reagent:local." <> node_name(name)

  defp authority(name, max_memory_bytes) do
    {:ok, blob} =
      Blob.parse(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          node_ref(name) => %{
            "limits" => %{
              "timeout" => "1m",
              "max_memory_bytes" => max_memory_bytes,
              "max_request_size" => 1_048_576,
              "max_response_size" => 5_242_880,
              "rate_limit" => %{"requests" => 100, "window" => "1m"},
              "max_concurrent_tasks" => 1,
              "batch_timeout" => "1m"
            },
            "edges" => %{"@ingress" => %{}}
          }
        }
      })

    profile = %{
      profile_id: "prof-#{node_name(name)}",
      consent_id: "consent-#{node_name(name)}",
      source_ref: node_ref(name),
      kind: :owner,
      invoke_mode: :open_inert,
      activation: %{node_ref(name) => "sha256:act-#{node_name(name)}"}
    }

    {:ok, authority} =
      Authority.root(profile, blob, ceiling: Sanctum.Policy.Ceiling.platform_ceiling())

    authority
  end

  # Run the guest `name` under a consent of `max_memory_bytes`, and answer
  # its result, its row and the runner that ran it, once the service holds
  # nothing of it.
  defp run!(ctx, name, max_memory_bytes) do
    id = Prima.UUID7.execution_id()

    result =
      Cyfr.Execution.Dispatch.run(ctx, node_ref(name) <> ":0.1.0", %{"hostile" => true},
        type: :reagent,
        authority: authority(name, max_memory_bytes),
        execution_id: id
      )

    attempt = Arca.ExecutionAttempts.current(Sanctum.Context.actor(ctx), id)
    wait_until(fn -> attempt.attempt not in OpusService.status().attempts end, 10_000)
    {result, Arca.Repo.get!(Arca.Schemas.Execution, id), attempt.claimed_by}
  end

  test "a guest past its bounds is refused by the engine, and its runner stays clean for the next",
       %{ctx: ctx} do
    tainted = OpusService.status().runners.tainted

    # A second linear memory: refused at instantiation, nothing of it run.
    {result, row, runner} = run!(ctx, "extra_memory", 64 * @mib)

    refused =
      "resource_limit: the engine refused the component's memory or tables " <>
        "(memory count too high at 2)"

    assert result == {:error, refused}
    assert row.status == "failed"
    assert row.error_message == refused
    assert is_binary(runner)

    # Growth: the consented total exactly, the table bound exactly, and
    # refused past both; the guest goes on and completes, in the same
    # runner, which the pool handed back only because it completed clean.
    for max <- [128 * @mib, 64 * @mib] do
      assert {{:ok, %{output: %{"pages" => pages, "table" => 20_000}}}, row, ^runner} =
               run!(ctx, "grower", max)

      assert pages * 65_536 == max
      assert row.status == "completed"
    end

    # A table past the bound: refused at instantiation.
    {result, row, ^runner} = run!(ctx, "wide_table", 64 * @mib)

    assert result ==
             {:error,
              "resource_limit: the engine refused the component's memory or tables " <>
                "(table minimum size of 20001 elements exceeds table limits)"}

    assert row.status == "failed"

    # The runner ran one more guest, clean, and none was tainted.
    assert {{:ok, _result}, _row, ^runner} = run!(ctx, "grower", 8 * @mib)
    assert OpusService.status().runners.tainted == tainted
  end
end
