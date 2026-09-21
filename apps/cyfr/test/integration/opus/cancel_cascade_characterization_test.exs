# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/nested_execution_helper.exs", __DIR__)

defmodule Opus.CancelCascadeCharacterizationTest do
  @moduledoc """
  Cancelling a formula ends everything it started. With a spawned child
  and a `run_stream` child in flight, a cancel leaves the formula's row
  cancelled with one terminal event and each child failed "Parent
  execution (…) terminated" with one terminal event; with the children
  held at a host call they made and never let go, nothing of the run is
  left: no waiter and no attempt on CYFR's side, and the runner the
  formula and its children ran in is ended and reported, holding nothing;
  the in-flight count, the execution slots and the charge rows (one for
  each child, the `run_stream` child's included) are back where they were.
  A cancel racing the formula's own completion leaves exactly one terminal
  outcome.

  The formula is the `nested-probe`, spawning one child, starting a
  `run_stream` child and awaiting the first, in a runner of its own; its
  children are the probe too, each asking for a catalog tool and held at
  that call on the suite's wire, in the formula's runner.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.Wait
  import Ecto.Query, only: [from: 2]

  alias Cyfr.Test.{OpusService, TwoServices}
  alias Opus.Test.NestedExecution, as: Probe
  alias Sanctum.Consent.{Bootstrap}

  @moduletag timeout: 120_000

  @probe_node "formula:local.nested-probe"
  @terminal Arca.ExecutionEvents.terminal_types()

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path =
      Path.join(System.tmp_dir!(), "cancel_cascade_#{System.unique_integer([:positive])}")

    keys = [:base_path]
    previous = Map.new(keys, &{&1, Application.get_env(:arca, &1)})
    Application.put_env(:arca, :base_path, test_path)

    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      Cyfr.Slots.forgive_unreaped(Cyfr.Execution.Slots, ctx.athanor_id)
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

    {:ok, ctx: ctx}
  end

  test "a cancelled formula leaves one cancelled row, failed children and nothing held", %{
    ctx: ctx
  } do
    slots_before = Cyfr.Slots.status(Cyfr.Execution.Slots).active
    root_id = Cyfr.UUID7.execution_id()
    hold_children!(root_id)

    root =
      start_root(ctx, root_id, %{
        "op" => "steps",
        "steps" => [%{"spawn" => run("run")}, %{"call" => run("run_stream")}, %{"await" => 0}]
      })

    held =
      for _ <- 1..2 do
        assert_receive {:held, id, _held}, 30_000
        id
      end

    authority = TwoServices.entered(root_id)

    # The guest admits its children in its steps' order: the spawned one,
    # then the streamed one.
    assert [spawned_id, stream_id] = admitted(root_id)
    assert Enum.sort(held) == Enum.sort([spawned_id, stream_id])

    assert Sanctum.Authority.budget(authority).in_flight == 2

    holders = for charge <- charges(ctx, authority), do: charge.holder_execution_id
    assert Enum.sort(holders) == Enum.sort([spawned_id, stream_id])

    # The formula and both children run in one runner, and every one of
    # them is waited on and attempted on CYFR's side.
    runner = runner_of(ctx, root_id)
    assert runner_of(ctx, spawned_id) == runner and runner_of(ctx, stream_id) == runner

    host_side =
      [root] ++
        for id <- [root_id, spawned_id, stream_id],
            process <- [waiter(id), Cyfr.Execution.Attempt.whereis(id)],
            do: process

    assert Enum.all?(host_side, &is_pid/1)
    assert Enum.all?(host_side, &Process.alive?/1)
    assert %{runners: %{busy: busy}} = OpusService.status()
    assert busy >= 1

    assert {:ok, %{cancelled: true}} = Cyfr.Execution.cancel(ctx, root_id)

    assert %{status: "cancelled"} = Arca.Repo.get!(Arca.Execution, root_id)
    assert ["execution.cancelled"] = terminal_events(ctx, root_id)

    for child_id <- [spawned_id, stream_id] do
      child = Arca.Repo.get!(Arca.Execution, child_id)
      assert child.status == "failed"
      assert child.error_message == "Parent execution (#{root_id}) terminated"
      assert child.parent_execution_id == root_id
      assert ["execution.failed"] = terminal_events(ctx, child_id)
    end

    # Nothing of the run is left: CYFR's side stops, and the runner is ended
    # and reported, the service holding none of its attempts.
    wait_until(fn -> not Enum.any?(host_side, &Process.alive?/1) end, 30_000)
    wait_until(fn -> reported_exit?(runner) end, 30_000, "the runner's exit report")
    wait_until(fn -> OpusService.status().attempts == [] end, 10_000)
    wait_until(fn -> Cyfr.Slots.status(Cyfr.Execution.Slots).active == slots_before end)
    assert Sanctum.Authority.budget(authority).in_flight == 0

    assert {:ok, _reclaimed} = Arca.BudgetReservations.sweep(Sanctum.Context.actor(ctx))
    assert charges(ctx, authority) == []

    assert %{charged: 0} =
             Arca.BudgetReservations.lookup(Sanctum.Context.actor(ctx), authority.budget.id)

    assert %{status: "cancelled"} = Arca.Repo.get!(Arca.Execution, root_id)
    assert ["execution.cancelled"] = terminal_events(ctx, root_id)

    for child_id <- [spawned_id, stream_id] do
      assert %{status: "failed"} = Arca.Repo.get!(Arca.Execution, child_id)
      assert ["execution.failed"] = terminal_events(ctx, child_id)
    end

    run = from(e in Arca.Execution, where: e.root_execution_id == ^root_id, select: e.id)
    assert Enum.sort(Arca.Repo.all(run)) == Enum.sort([root_id, spawned_id, stream_id])
  end

  test "a cancel racing the formula's completion leaves exactly one terminal outcome", %{
    ctx: ctx
  } do
    # The cancel lands at staggered points of the run's last moments: while
    # its close crosses the wire, as CYFR records it, and after its row closed.
    for delay <- [0, 1, 2, 3, 4, 5, 6, 8, 12, 20, 80] do
      root_id = Cyfr.UUID7.execution_id()
      TwoServices.hold!(:complete, root_id, once: true)
      root = start_root(ctx, root_id, %{"op" => "echo"})
      assert_receive {:held, ^root_id, close}, 30_000

      test_pid = self()

      spawn(fn ->
        Process.sleep(delay)
        send(test_pid, {:cancelled, Cyfr.Execution.cancel(ctx, root_id)})
      end)

      TwoServices.release!(close)
      assert_receive {:cancelled, cancel}, 30_000
      wait_until(fn -> not Process.alive?(root) end, 30_000)

      row = Arca.Repo.get!(Arca.Execution, root_id)
      assert [terminal] = terminal_events(ctx, root_id)

      case row.status do
        "cancelled" ->
          assert {:ok, %{cancelled: true}} = cancel
          assert terminal == "execution.cancelled"

        "completed" ->
          assert {:error, _} = cancel
          assert terminal == "execution.completed"
      end

      assert %{state: state} =
               Arca.ExecutionAttempts.get(Sanctum.Context.actor(ctx), row.current_attempt)

      refute state == "running"
    end
  end

  # A root run of the probe in a process of its own, which waits on it.
  defp start_root(ctx, root_id, input) do
    test_pid = self()

    spawn(fn ->
      send(
        test_pid,
        {:root,
         Cyfr.Execution.run_root(ctx, :default, Probe.probe_ref(), input, execution_id: root_id)}
      )
    end)
  end

  # Each child of the root asks for a catalog tool, and is held at that
  # call: the test receives `{:held, id, held}` for each.
  defp hold_children!(root_id) do
    TwoServices.hold!(
      :tool_call,
      fn row, _call -> row != nil and row.parent_execution_id == root_id end,
      []
    )
  end

  defp run(action) do
    %{
      "tool" => "execution",
      "action" => action,
      "args" => %{
        "reference" => Probe.probe_ref(),
        "input" => Probe.held_input(),
        "type" => "formula"
      }
    }
  end

  # The children the formula `parent_id` was admitted, in the order its
  # runner asked, as the admissions' answers crossed the wire.
  defp admitted(parent_id) do
    for %{fields: %{execution_id: ^parent_id}, answer: %{"ok" => %{"assignment" => token}}} <-
          TwoServices.calls(),
        {:ok, %{execution_id: id}} <- [Cyfr.Assignment.read(token)],
        do: id
  end

  # The process registered under `id`: its run's waiter, registered with
  # the endpoint of the worker service the run was dispatched to.
  defp waiter(id) do
    [{pid, {:dispatched, %{id: "wrk_local"}}}] = Registry.lookup(Cyfr.Execution.Registry, id)
    pid
  end

  # The runner that claimed the run's attempt, as its host calls present it.
  defp runner_of(ctx, id),
    do: Arca.ExecutionAttempts.current(Sanctum.Context.actor(ctx), id).claimed_by

  defp reported_exit?(runner) do
    Enum.any?(
      TwoServices.calls(),
      &match?(%{callback: :runner_exited, args: %{"runner" => ^runner}}, &1)
    )
  end

  defp terminal_events(ctx, id) do
    {:ok, rows} = Arca.ExecutionEvents.since(Sanctum.Context.actor(ctx), id, 0)
    for %{type: type} <- rows, type in @terminal, do: type
  end

  defp charges(ctx, authority) do
    {:ok, charges} =
      Arca.BudgetReservations.charges(Sanctum.Context.actor(ctx), authority.budget.id)

    charges
  end
end
