# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.AttemptAbandonedTest do
  @moduledoc """
  A run the runtime abandoned, killed with its native work possibly still
  running, closes failed with its attempt's outcome `uncertain` under the
  runtime's message, whatever asked for the kill, and its kill is counted
  against the athanor. A row another close already ended stands as that
  close wrote it: a person's cancel reads cancelled, a lapse reads as the
  lapse wrote it, and the late report writes nothing to the row; a
  formula's children still running are stopped, though the cancel that
  ended its row died before it stopped them, and a second pass after a
  cancel that stopped them leaves them as it did. A failure the runtime
  did not abandon closes failed as the run's own error.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Test.{AttemptFixtures, AttemptWaiter}

  @timeout "Execution timeout after 5000ms"
  @cancelled "Execution cancelled before it completed"
  @lease_lost "Execution lease lost: the row is no longer this attempt's to finish"

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    fixture = AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api))
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, fixture.athanor_id) end)
    {:ok, fixture: fixture, id: fixture.execution_id}
  end

  test "a run its runtime stopped at its budget closes uncertain under the runtime's message",
       %{fixture: fixture, id: id} do
    assert %{"ok" => @timeout} = abandoned(fixture, @timeout)
    assert {:error, {:uncertain, @timeout}} = AttemptWaiter.await(fixture.pid, fixture.close)

    assert %{status: "failed", error_class: "uncertain", error_message: @timeout} = row(id)
    assert %{outcome: "uncertain"} = attempt(fixture)
    assert unreaped(fixture) == 1
  end

  test "a failure its runtime did not abandon closes as the run's own error",
       %{fixture: fixture, id: id} do
    assert %{"ok" => "it broke"} = failed(fixture, "it broke")
    assert {:error, "it broke"} = AttemptWaiter.await(fixture.pid, fixture.close)

    assert %{status: "failed", error_class: "internal", error_message: "it broke"} = row(id)
    assert %{outcome: "error"} = attempt(fixture)
    assert unreaped(fixture) == 0
  end

  test "a run its person cancelled reads cancelled when the runtime's report of the kill follows",
       %{fixture: fixture, id: id} do
    assert {:ok, %{cancelled: true}} = Opus.cancel(fixture.ctx, id)
    cancelled = row(id)
    assert %{status: "cancelled", error_class: "cancelled"} = cancelled

    # The runtime reports the kill it made for the cancel: the row stands.
    abandoned(fixture, @cancelled)
    assert {:error, "Execution cancelled"} = AttemptWaiter.await(fixture.pid, fixture.close)
    assert row(id) == cancelled
  end

  test "a run stopped at its budget before its person's cancel reads as the timeout closed it",
       %{fixture: fixture, id: id} do
    assert %{"ok" => @timeout} = abandoned(fixture, @timeout)
    assert {:error, {:uncertain, @timeout}} = AttemptWaiter.await(fixture.pid, fixture.close)
    closed = row(id)

    assert {:error, :not_cancellable} = Opus.cancel(fixture.ctx, id)
    assert %{status: "failed", error_class: "uncertain", error_message: @timeout} = row(id)
    assert row(id) == closed
  end

  test "a run whose lease was lost reads as the lapse closed it when the runtime's report follows",
       %{fixture: fixture, id: id} do
    assert {:ok, [_]} = Opus.Lapse.boot(fixture.service, fixture.boot, [fixture.attempt])
    lapsed = row(id)
    assert %{status: "failed", error_class: "uncertain"} = lapsed

    abandoned(fixture, @lease_lost)
    assert {:error, {:uncertain, error}} = AttemptWaiter.await(fixture.pid, fixture.close)
    assert error == lapsed.error_message
    assert row(id) == lapsed
  end

  describe "a formula whose cancel wrote its row and died before it stopped the children" do
    setup %{fixture: fixture} do
      parent = AttemptFixtures.attached!(ctx: fixture.ctx, component_type: :formula)
      on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, parent.athanor_id) end)
      {:ok, parent: parent, child: child!(parent)}
    end

    test "a late abandoned report stops the children", %{parent: parent, child: child} do
      # The report passes its ownership check before the cancel writes.
      checked = hold_after_ownership_check(parent)
      reporter = Task.async(fn -> abandoned(parent, @cancelled) end)
      assert_receive {:checked, checker}, 2_000

      cancel_dying_after_row!(parent)
      assert row(child.id).status == "running"

      send(checker, :continue)
      assert %{"ok" => _} = Task.await(reporter, 5_000)
      assert {:error, "Execution cancelled"} = AttemptWaiter.await(parent.pid, parent.close)
      assert row(parent.execution_id).status == "cancelled"
      assert row(child.id).status == "failed"
      :telemetry.detach(checked)
    end

    test "an attempt that ends before it closes the run stops the children",
         %{parent: parent, child: child} do
      cancel_dying_after_row!(parent)
      assert row(child.id).status == "running"

      attempt = parent.pid
      ref = Process.monitor(attempt)
      Process.exit(attempt, :kill)
      assert_receive {:DOWN, ^ref, :process, ^attempt, :killed}

      assert {:error, "Execution cancelled"} = AttemptWaiter.await(attempt, parent.close)
      assert row(parent.execution_id).status == "cancelled"
      assert row(child.id).status == "failed"
    end
  end

  test "an abandoned report after a cancel that stopped the children leaves them as it did",
       %{fixture: fixture} do
    parent = AttemptFixtures.attached!(ctx: fixture.ctx, component_type: :formula)
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, parent.athanor_id) end)
    child = child!(parent)

    # The report passes its ownership check, then the cancel ends the row
    # and stops the children itself: the report's close cascades a second
    # time.
    checked = hold_after_ownership_check(parent)
    reporter = Task.async(fn -> abandoned(parent, @cancelled) end)
    assert_receive {:checked, checker}, 2_000

    assert {:ok, %{cancelled: true}} = Opus.cancel(parent.ctx, parent.execution_id)
    actor = Prima.Actor.in_athanor(parent.athanor_id)
    stopped = Arca.Repo.get!(Arca.Schemas.Execution, child.id)
    ended = Arca.Repo.get!(Arca.Schemas.Execution, parent.execution_id)
    assert stopped.status == "failed"
    assert {:ok, events} = Arca.ExecutionEvents.since(actor, child.id, 0)

    send(checker, :continue)
    assert %{"ok" => _} = Task.await(reporter, 5_000)
    assert {:error, "Execution cancelled"} = AttemptWaiter.await(parent.pid, parent.close)
    assert Arca.Repo.get!(Arca.Schemas.Execution, child.id) == stopped
    assert Arca.Repo.get!(Arca.Schemas.Execution, parent.execution_id) == ended
    assert {:ok, ^events} = Arca.ExecutionEvents.since(actor, child.id, 0)
    :telemetry.detach(checked)
  end

  # A running child of `parent`, as a formula's guest admits one.
  defp child!(parent) do
    child =
      Opus.Record.new(parent.ctx, "reagent:local.abandoned-child:1.0.0", %{},
        component_type: :reagent,
        parent_execution_id: parent.execution_id,
        root_execution_id: parent.execution_id
      )

    :ok = Opus.Record.write_started(parent.ctx, child, parent_attempt: parent.attempt)
    child
  end

  # A person's cancel of `parent` that writes its row and is killed before
  # it stops the children: its terminal event is held in the parent's
  # event buffer until the canceller is gone.
  defp cancel_dying_after_row!(parent) do
    [{buffer, _}] = Registry.lookup(Opus.Events.Registry, parent.execution_id)
    on_exit(fn -> if Process.alive?(buffer), do: :sys.resume(buffer) end)
    :ok = :sys.suspend(buffer)

    {canceller, watch} = spawn_monitor(fn -> Opus.cancel(parent.ctx, parent.execution_id) end)
    wait_until(fn -> row(parent.execution_id).status == "cancelled" end)
    Process.exit(canceller, :kill)
    assert_receive {:DOWN, ^watch, :process, ^canceller, :killed}, 2_000
    :ok = :sys.resume(buffer)
  end

  # The parent's attempt pauses once, past the query that checks its
  # ownership of the report, until it is sent `:continue`.
  defp hold_after_ownership_check(parent) do
    observer = self()
    handler = {__MODULE__, :checked, make_ref()}
    on_exit(fn -> :telemetry.detach(handler) end)

    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, meta, observer ->
          if self() == parent.pid and parent.attempt in (meta[:params] || []) and
               not Process.get(:checked, false) do
            Process.put(:checked, true)
            send(observer, {:checked, self()})

            receive do
              :continue -> :ok
            after
              5_000 -> :ok
            end
          end
        end,
        observer
      )

    handler
  end

  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("the condition never held")
      true -> Process.sleep(5) && wait_until(fun, deadline)
    end
  end

  defp abandoned(fixture, error), do: fail(fixture, %{"error" => error, "abandoned" => true})
  defp failed(fixture, error), do: fail(fixture, %{"error" => error, "abandoned" => false})

  defp fail(fixture, fields) do
    AttemptFixtures.call(fixture, "fail", %{
      "outcome" => AttemptFixtures.outcome(fixture, "failed", fields)
    })
  end

  defp row(id) do
    Arca.Schemas.Execution
    |> Arca.Repo.get!(id)
    |> Map.take([:status, :error_class, :error_message, :completed_at])
  end

  defp attempt(fixture),
    do:
      Arca.ExecutionAttempts.current(
        Prima.Actor.in_athanor(fixture.athanor_id),
        fixture.execution_id
      )

  defp unreaped(fixture),
    do: Map.get(Prima.Slots.status(Opus.Slots).unreaped, fixture.athanor_id, 0)
end
