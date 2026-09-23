# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/nested_execution_helper.exs", __DIR__)

defmodule Opus.ExecutorCancelPenaltyTest do
  @moduledoc """
  A cancel is counted against the tenant as an unreaped kill once for each
  run it killed whose runner ran, and never for a kill that reached nothing
  native; enough of them put the tenant in the penalty box, which refuses
  its next root.

  The runs are the `nested-probe` formula on the Opus service, each held at
  its completion on the suite's wire, so the cancel lands while the run's
  runner is still at its work and the completion crosses after the cancel:
  the cancel's kill ends the runner, and the waiter's kill of its lost run
  finds it ended, which the worker service answers `:ok` as it answers a
  kill of a live runner (`c:Cyfr.WorkerAPI.kill/1`). Each run is waited on
  by a process of its own, and its notes are counted once that process has
  its answer, when every kill of the run has been made.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Slots
  alias Cyfr.Test.TwoServices
  alias Opus.Test.NestedExecution, as: Probe
  alias Sanctum.Consent.{Bootstrap}

  @moduletag timeout: 180_000

  @slots Cyfr.Execution.Slots
  @probe_node "formula:local.nested-probe"
  @unreaped_kill [:cyfr, :opus, :execution, :unreaped_kill]

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path =
      Path.join(System.tmp_dir!(), "cancel_penalty_#{System.unique_integer([:positive])}")

    keys = [:base_path]
    previous = Map.new(keys, &{&1, Application.get_env(:arca, &1)})
    Application.put_env(:arca, :base_path, test_path)

    ctx = Sanctum.TestContext.local()

    # The penalty box outlives a force-release: what this suite fills for
    # its tenant, it empties.
    on_exit(fn ->
      Slots.forgive_unreaped(@slots, ctx.athanor_id)
      File.rm_rf!(test_path)

      for {key, value} <- previous do
        if value,
          do: Application.put_env(:arca, key, value),
          else: Application.delete_env(:arca, key)
      end
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()

    :ok = Probe.publish_probe!(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @probe_node in minted

    handler = "cancel-penalty-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler, @unreaped_kill, &__MODULE__.forward_unreaped/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    Slots.forgive_unreaped(@slots, ctx.athanor_id)
    {:ok, ctx: ctx}
  end

  @doc false
  def forward_unreaped(_event, %{unreaped_count: count}, metadata, test),
    do: send(test, {:unreaped_kill, metadata.execution_id, count})

  test "a cancel racing the formula's completion is counted once", %{ctx: ctx} do
    id = cancelled_at_completion!(ctx)
    assert noted(id) == 1
    assert %{status: "cancelled"} = Arca.Repo.get!(Arca.Schemas.Execution, id)
  end

  test "as many cancelled runs as the threshold put the tenant in the penalty box, and one fewer does not",
       %{ctx: ctx} do
    threshold = Slots.unreaped_threshold(Slots.status(@slots).key_max)

    for n <- 1..(threshold - 1) do
      assert noted(cancelled_at_completion!(ctx)) == 1
      assert Slots.status(@slots).unreaped[ctx.athanor_id] == n
    end

    # One short of the threshold, the tenant's roots are still admitted.
    assert {:ok, ref} = Slots.acquire(@slots, ctx.athanor_id, :root, wait_ms: 0)
    :ok = Slots.release(@slots, ref)

    assert noted(cancelled_at_completion!(ctx)) == 1
    assert Slots.status(@slots).unreaped[ctx.athanor_id] == threshold

    assert {:error, :key_unreaped} =
             Slots.acquire(@slots, ctx.athanor_id, :root, wait_ms: 1_000)
  end

  test "a holder on this node runs nothing native: its cancel kills it and is not counted",
       %{ctx: ctx} do
    id = running!(ctx)

    # What a background task that registered its run and has not yet
    # dispatched it, or a turn root's holder, looks like to the cancel.
    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, _} = Registry.register(Cyfr.Execution.Registry, id, :running)
        Process.sleep(:infinity)
      end)

    wait_until_registered(id)

    assert {:ok, %{cancelled: true, execution_id: ^id}} = Cyfr.Execution.cancel(ctx, id)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
    assert noted(id) == 0
    refute Map.has_key?(Slots.status(@slots).unreaped, ctx.athanor_id)
  end

  # A run of the probe whose completion is held on the suite's wire and
  # cancelled there; answered once its waiter has its answer. The cancel's
  # terminal write, its kill and its note are all made before the
  # completion is let go.
  defp cancelled_at_completion!(ctx) do
    id = Cyfr.UUID7.execution_id()
    TwoServices.hold!(:complete, id, once: true)
    waiter = start_root(ctx, id, %{"op" => "echo"})
    assert_receive {:held, ^id, close}, 30_000

    assert {:ok, %{cancelled: true}} = Cyfr.Execution.cancel(ctx, id)
    TwoServices.release!(close)

    assert_receive {:root, ^waiter, {:error, _cancelled}}, 30_000
    id
  end

  # A root run of the probe in a process of its own, its waiter, which
  # tells the test what the run answered.
  defp start_root(ctx, id, input) do
    test_pid = self()

    spawn(fn ->
      answer =
        Cyfr.Execution.run_root(ctx, :default, Probe.probe_ref(), input, execution_id: id)

      send(test_pid, {:root, self(), answer})
    end)
  end

  # The unreaped kills noted for `id` so far. A waiter's note precedes its
  # answer, and a cancel's precedes its return, so once both are in hand
  # every note of the run is in the mailbox.
  defp noted(id) do
    {:messages, messages} = Process.info(self(), :messages)
    Enum.count(messages, &match?({:unreaped_kill, ^id, _count}, &1))
  end

  defp running!(ctx) do
    id = Cyfr.UUID7.execution_id()

    {:ok, _} =
      Arca.Execution.record_start(%{
        id: id,
        reference: "catalyst:local.test:1.0.0",
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        started_at: DateTime.utc_now(),
        status: "running",
        component_type: "catalyst"
      })

    id
  end

  defp wait_until_registered(id) do
    Cyfr.Test.Wait.wait_until(
      fn -> match?([{_pid, :running}], Registry.lookup(Cyfr.Execution.Registry, id)) end,
      5_000,
      "the holder registered"
    )
  end
end
