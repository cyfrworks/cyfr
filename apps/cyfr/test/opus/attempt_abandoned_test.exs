# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.AttemptAbandonedTest do
  @moduledoc """
  A run the runtime abandoned, killed with its native work possibly still
  running, closes failed with its attempt's outcome `uncertain` under the
  runtime's message, whatever asked for the kill, and its kill is counted
  against the athanor. A row another close already ended stands as that
  close wrote it: a person's cancel reads cancelled, a lapse reads as the
  lapse wrote it, and the late report writes nothing. A failure the
  runtime did not abandon closes failed as the run's own error.
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
