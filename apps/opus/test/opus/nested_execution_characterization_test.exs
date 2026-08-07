# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Opus.NestedExecutionCharacterizationTest do
  # Documents TODAY's closure-capture behavior across the execution spawn
  # layers as the diff baseline for the Authority cutover — these tests pin
  # the current confused-deputy shape on purpose and fix nothing.
  #
  # Layers exercised here: the ToolRegistry Task.async wrapper (every
  # dispatch), the executor's execute_with_timeout spawn_link (every
  # level), and the AsyncTracker Task.Supervisor (spawn ops). The
  # remaining three layers — run_stream's Task.Supervisor, the SSE
  # HttpStreamHandler bare spawn, and the cron Task.Supervisor — are
  # covered by their own suites; the Authority plumbing conformance test
  # must cover all six.
  use ExUnit.Case, async: false

  alias Opus.Test.NestedExecution, as: Probe

  @moduletag timeout: 180_000

  setup do
    test_path = Path.join(System.tmp_dir!(), "nested_probe_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()
    :ok = Probe.publish_probe!(ctx)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: ctx}
  end

  test "the probe executes end to end as a real Component Model binary", %{ctx: ctx} do
    {:ok, output, result} = Probe.run_probe(ctx, %{"op" => "echo", "hello" => "world"})

    assert result.status == :completed
    assert output["op"] == "echo"
    assert output["input"]["hello"] == "world"
  end

  test "generic tool dispatch runs under the caller's context with no authority consulted",
       %{ctx: ctx} do
    # A non-execution tool (component.search) succeeds purely on the
    # caller's permissions — the capability model's §1 problem, pinned.
    {:ok, output, _result} =
      Probe.run_probe(ctx, %{
        "op" => "call",
        "request" => %{
          "tool" => "component",
          "action" => "search",
          "args" => %{"query" => "nested-probe"}
        }
      })

    assert %{"status" => "completed", "output" => search_result} =
             Jason.decode!(output["result_raw"])

    assert is_map(search_result)
  end

  test "tool containment today is the policy allowlist, deny-by-default", %{ctx: ctx} do
    # secret.list is neither hard-restricted nor in the probe's
    # allowed_tools — the soft allowlist denies it.
    {:ok, output, _result} =
      Probe.run_probe(ctx, %{
        "op" => "call",
        "request" => %{"tool" => "secret", "action" => "list", "args" => %{}}
      })

    assert %{"error" => %{"type" => "tool_denied"}} = Jason.decode!(output["result_raw"])
  end

  test "a chain is a real nested execution and the SAME identity reaches every level",
       %{ctx: ctx} do
    {:ok, output, result} = Probe.run_chain(ctx, 2)

    assert result.status == :completed

    levels = Probe.unwrap_chain(output)
    assert [%{depth: 2} = l2, %{depth: 1} = l1, %{depth: 0}] = levels

    # Three distinct executions really ran…
    assert l2.child_execution_id != l1.child_execution_id
    assert l2.child_status == "completed"
    assert l1.child_status == "completed"

    # …every one of them as the ORIGINAL caller. This is the confused-deputy
    # baseline the run_root/run_child split replaces.
    assert l2.child_user_id == ctx.user_id
    assert l1.child_user_id == ctx.user_id
  end

  test "spawned dispatches run inside the AsyncTracker closure with the captured context",
       %{ctx: ctx} do
    echo_run = %{
      "tool" => "execution",
      "action" => "run",
      "args" => %{
        "reference" => Probe.probe_ref(),
        "input" => %{"op" => "echo"},
        "type" => "formula"
      }
    }

    {:ok, output, _result} =
      Probe.run_probe(ctx, %{"op" => "spawn_await_all", "requests" => [echo_run, echo_run]})

    # Task ids are per-tracker ordinals.
    assert output["task_ids"] == ["task_1", "task_2"]

    # await-all responds bare — no {"status","output"} wrapper, unlike call.
    assert %{"count" => 2, "results" => results} = Jason.decode!(output["result_raw"])

    # Both spawned children executed for real, as the captured caller.
    for wrapped <- results do
      assert wrapped["status"] == "completed"

      run_response = wrapped["output"]
      assert run_response["status"] == "completed"
      assert run_response["user_id"] == ctx.user_id
      assert run_response["result"]["op"] == "echo"
    end
  end

  test "emitted events reach the root buffer in the plain envelope, with no origin marker",
       %{ctx: ctx} do
    {:ok, output, result} =
      Probe.run_probe(ctx, %{"op" => "emit", "payload" => %{"note" => "from-guest"}})

    assert %{"ok" => true, "sequence" => sequence} = Jason.decode!(output["emit_raw"])
    assert is_integer(sequence)

    execution_id = result.metadata.execution_id
    events = Opus.ExecutionEventBuffer.since(execution_id, 0, ctx.org_id)
    emit_event = Enum.find(events, &(&1.type == "emit" and &1.sequence == sequence))

    assert emit_event, "guest emit not found in the root buffer"
    assert emit_event.data == %{"note" => "from-guest"}

    # The D6 baseline: host- and guest-generated events share this exact
    # five-key envelope — nothing marks provenance.
    assert Map.keys(emit_event) |> Enum.sort() ==
             [:data, :execution_id, :sequence, :timestamp, :type]
  end
end
