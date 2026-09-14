# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.CancelCascadeCharacterizationTest do
  @moduledoc """
  Cancelling a formula ends everything it started. With a spawned child
  and a `run_stream` child in flight, a cancel leaves the formula's row
  cancelled with one terminal event and each child failed "Parent
  execution (…) terminated" with one terminal event; once the children
  held at their guest's entry are let go, no process of the run is alive
  and the in-flight count, the execution slots and the charge rows are
  back where they were. A cancel racing the formula's own completion
  leaves exactly one terminal outcome.

  The formula is the `nested-probe`, spawning one child and awaiting it;
  its children are the probe too, held at the entry to their guest until
  the test lets them go. The probe issues one operation per run, so the
  `run_stream` child is started by the test through the formula's own
  `call` host function (`Opus.FormulaHandler.execute/3`), with the
  formula's authority, attempt and lineage, while the formula awaits its
  spawned child.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.Wait
  import Ecto.Query, only: [from: 2]

  alias Opus.Test.NestedExecution, as: Probe
  alias Sanctum.Consent.{Bootstrap, Source}

  @moduletag timeout: 120_000

  @probe_node "formula:local.nested-probe"
  @terminal Arca.ExecutionEvents.terminal_types()

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path =
      Path.join(System.tmp_dir!(), "cancel_cascade_#{System.unique_integer([:positive])}")

    keys = [:base_path, :consent_source]
    previous = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :consent_source, Source.DB)

    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      Cyfr.Execution.Semaphore.forgive_unreaped(ctx.athanor_id)
      File.rm_rf!(test_path)

      for {key, value} <- previous do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
      end
    end)

    :ok = Probe.publish_probe!(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @probe_node in minted

    {:ok, ctx: ctx}
  end

  test "a cancelled formula leaves one cancelled row, failed children and nothing held", %{
    ctx: ctx
  } do
    slots_before = Cyfr.Execution.Semaphore.status().active
    root_id = Cyfr.UUID7.execution_id()
    hold!(root_id)

    root = start_root(ctx, root_id, %{"op" => "spawn_await", "request" => run("run")})

    assert_receive {:entered, ^root_id, authority}, 30_000
    assert_receive {:held, spawned_runner, spawned_id}, 30_000
    row = Arca.Repo.get!(Arca.Execution, root_id)

    streamed =
      Opus.FormulaHandler.execute(run_json("run_stream"), Sanctum.Context.enter_guest(ctx),
        parent_execution_id: root_id,
        root_execution_id: root_id,
        attempt: row.current_attempt,
        authority: authority,
        declared_needs: [],
        activation_digest: row.activation_digest,
        parent_reference: Probe.probe_ref()
      )

    assert %{"output" => %{"execution_id" => stream_id}} = Jason.decode!(streamed)
    assert_receive {:held, stream_runner, ^stream_id}, 30_000

    assert Sanctum.Authority.budget(authority).in_flight == 2

    [{_, root_meta}] = Registry.lookup(Cyfr.Execution.Registry, root_id)
    [{spawned_driver, _}] = Registry.lookup(Cyfr.Execution.Registry, spawned_id)
    [{stream_driver, _}] = Registry.lookup(Cyfr.Execution.Registry, stream_id)

    processes = [
      root,
      root_meta.runner_pid,
      root_meta.tracker_pid,
      spawned_driver,
      spawned_runner,
      stream_driver,
      stream_runner
    ]

    assert Enum.all?(processes, &Process.alive?/1)

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

    for runner <- [spawned_runner, stream_runner], do: send(runner, :continue)

    wait_until(fn -> not Enum.any?(processes, &Process.alive?/1) end, 30_000)
    wait_until(fn -> Cyfr.Execution.Semaphore.status().active == slots_before end)
    assert Sanctum.Authority.budget(authority).in_flight == 0

    assert {:ok, _reclaimed} = Arca.BudgetReservations.sweep(ctx.athanor_id)
    assert charges(ctx, authority) == []
    assert %{charged: 0} = Arca.BudgetReservations.lookup(ctx.athanor_id, authority.budget.id)

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
    # its guest runs, while it finalizes, and after its row closed.
    for delay <- [0, 1, 2, 3, 4, 5, 6, 8, 12, 20, 80] do
      root_id = Cyfr.UUID7.execution_id()
      hold!(root_id, hold_root: true)
      root = start_root(ctx, root_id, %{"op" => "echo"})
      assert_receive {:held, runner, ^root_id}, 30_000

      test_pid = self()

      spawn(fn ->
        Process.sleep(delay)
        send(test_pid, {:cancelled, Cyfr.Execution.cancel(ctx, root_id)})
      end)

      send(runner, :continue)
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

      assert %{state: state} = Arca.ExecutionAttempts.get(ctx.athanor_id, row.current_attempt)
      refute state == "running"
    end
  end

  # A root run of the probe in a process of its own, which a cancel kills.
  defp start_root(ctx, root_id, input) do
    test_pid = self()

    spawn(fn ->
      send(
        test_pid,
        {:root, Opus.run_root(ctx, :default, Probe.probe_ref(), input, execution_id: root_id)}
      )
    end)
  end

  # Report the root's authority as it enters its guest; hold each child of
  # the root (and the root itself with `hold_root: true`) at its guest's
  # entry until it is sent `:continue`.
  defp hold!(root_id, opts \\ []) do
    test_pid = self()
    hold_root? = Keyword.get(opts, :hold_root, false)
    handler = "cancel-cascade-hold-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:cyfr, :opus, :runtime, :authority_entered],
        fn _event, _measurements, %{execution_id: id, authority: authority}, _config ->
          held? =
            case Arca.Repo.get(Arca.Execution, id) do
              %{id: ^root_id} ->
                send(test_pid, {:entered, id, authority})
                hold_root?

              %{parent_execution_id: ^root_id} ->
                true

              _ ->
                false
            end

          if held? do
            send(test_pid, {:held, self(), id})

            receive do
              :continue -> :ok
            after
              60_000 -> :ok
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp run(action) do
    %{
      "tool" => "execution",
      "action" => action,
      "args" => %{
        "reference" => Probe.probe_ref(),
        "input" => %{"op" => "echo"},
        "type" => "formula"
      }
    }
  end

  defp run_json(action), do: Jason.encode!(run(action))

  defp terminal_events(ctx, id) do
    {:ok, rows} = Arca.ExecutionEvents.since(ctx.athanor_id, id, 0)
    for %{type: type} <- rows, type in @terminal, do: type
  end

  defp charges(ctx, authority) do
    {:ok, charges} = Arca.BudgetReservations.charges(ctx.athanor_id, authority.budget.id)
    charges
  end
end
