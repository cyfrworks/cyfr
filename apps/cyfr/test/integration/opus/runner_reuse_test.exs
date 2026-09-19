# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/nested_execution_helper.exs", __DIR__)

defmodule Opus.RunnerReuseTest do
  @moduledoc """
  A runner the pool reuses carries nothing of the subtree it ran before.
  The pool keeps a runner that completed clean idle for its athanor and
  hands it to that athanor's next subtree, so a second run of an athanor
  runs in the runner of the first. The athanor here is one of the test's
  own, so the first run's runner is the only one idle for it.

  The first run spawns a child in its runner and awaits it. While the
  second is held at a host call in that same runner, the service reports
  it holding the second's attempt alone; a kill of the first, an
  execution this boot already ended, reaches nothing, and a kill of an
  execution no runner held answers `not_found` however busy the runner
  is; the second entered with its own authority, completes clean in the
  runner, and a task the first spawned is no task of the second.
  What happened is read at the wire, the status the service answers and
  the rows.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.Wait

  alias Cyfr.Execution.WorkerClient
  alias Cyfr.Test.{OpusService, TwoServices}
  alias Opus.Test.NestedExecution, as: Probe
  alias Sanctum.Consent.{Bootstrap, Source}

  @moduletag timeout: 120_000

  @probe_node "formula:local.nested-probe"

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)
    TwoServices.watch!()

    test_path = Path.join(System.tmp_dir!(), "runner_reuse_#{System.unique_integer([:positive])}")
    keys = [:base_path, :consent_source]
    previous = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :consent_source, Source.DB)

    unique = System.unique_integer([:positive])

    {:ok, athanor} =
      Sanctum.Tenancy.Athanors.create_for_operator(%{
        kind: "group",
        name: "Reuse #{unique}",
        slug: "reuse-#{unique}",
        created_by: "system"
      })

    ctx = %{Sanctum.TestContext.local() | athanor_id: athanor.id}

    on_exit(fn ->
      Cyfr.Slots.forgive_unreaped(Cyfr.Execution.Slots, ctx.athanor_id)
      File.rm_rf!(test_path)

      for {key, value} <- previous do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
      end
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()

    :ok = Probe.publish_probe!(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @probe_node in minted

    {:ok, ctx: ctx}
  end

  test "a pooled runner reused by a second run carries nothing of the first", %{ctx: ctx} do
    first_id = Cyfr.UUID7.execution_id()

    {:ok, first} =
      Cyfr.Execution.run_root(
        ctx,
        :default,
        Probe.probe_ref(),
        steps([%{"spawn" => echo()}, %{"await" => 0}]),
        execution_id: first_id
      )

    assert first.status == :completed
    assert [_spawned, awaited] = first.output["results"]
    assert %{"task_id" => "task_1", "status" => "completed"} = Jason.decode!(awaited)

    runner = runner_of(ctx, first_id)
    first_attempt = attempt_of(ctx, first_id)

    # The first run's runner is back in the pool, idle for this athanor,
    # once the service holds none of its attempts.
    wait_until(fn -> first_attempt not in OpusService.status().attempts end, 10_000)

    # The second run asks for a catalog tool and is held at that call, in
    # the middle of its work; then it polls the first run's task by name.
    second_id = Cyfr.UUID7.execution_id()
    TwoServices.hold!(:tool_call, second_id, once: true)
    test_pid = self()

    spawn(fn ->
      input = steps([%{"call" => Probe.held_input()["request"]}, %{"poll" => "task_1"}])

      send(
        test_pid,
        {:second,
         Cyfr.Execution.run_root(ctx, :default, Probe.probe_ref(), input, execution_id: second_id)}
      )
    end)

    assert_receive {:held, ^second_id, call}, 30_000

    assert runner_of(ctx, second_id) == runner
    assert %{attempts: [second_attempt]} = OpusService.status()
    assert second_attempt == attempt_of(ctx, second_id)

    # A kill of the first run is one of an execution this boot already
    # ended: answered, and never reaching the runner now running the
    # second. A kill of an execution no runner held is not found, however
    # busy the runners are.
    assert :ok = WorkerClient.kill(OpusService.endpoint(), first_id)

    assert {:error, :not_found} =
             WorkerClient.kill(OpusService.endpoint(), Cyfr.UUID7.execution_id())

    assert %{attempts: [^second_attempt], runners: %{busy: 1, tainted: 0}} = OpusService.status()

    authority = TwoServices.entered(second_id)
    assert authority.cursor == {:bound, @probe_node}
    assert authority.depth == 0
    refute authority.budget.id == TwoServices.entered(first_id).budget.id

    TwoServices.release!(call)
    assert_receive {:second, {:ok, second}}, 30_000
    assert second.status == :completed

    # The kill of the first reached nothing: the runner completed the second
    # clean, and went back to the pool.
    second_attempt = attempt_of(ctx, second_id)
    wait_until(fn -> second_attempt not in OpusService.status().attempts end, 10_000)
    assert %{runners: %{busy: 0, tainted: 0}} = OpusService.status()

    # The first run's task is no task of the second's formula.
    assert [called, polled] = second.output["results"]
    assert %{"status" => "completed"} = Jason.decode!(called)

    assert %{"error" => %{"type" => "invalid_request", "message" => "Unknown task_id: task_1"}} =
             Jason.decode!(polled)
  end

  defp steps(steps), do: %{"op" => "steps", "steps" => steps}

  defp echo do
    %{
      "tool" => "execution",
      "action" => "run",
      "args" => %{
        "reference" => Probe.probe_ref(),
        "input" => %{"op" => "echo"},
        "type" => "formula"
      }
    }
  end

  defp runner_of(ctx, id), do: Arca.ExecutionAttempts.current(ctx.athanor_id, id).claimed_by
  defp attempt_of(ctx, id), do: Arca.ExecutionAttempts.current(ctx.athanor_id, id).attempt
end
