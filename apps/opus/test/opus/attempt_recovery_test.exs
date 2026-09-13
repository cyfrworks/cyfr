# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.AttemptRecoveryTest do
  @moduledoc """
  A runner that died mid-execution leaves an attempt whose lease lapses:
  the sweeper retires it and fails the row, its late result is refused by
  the fence, and a successor opens with the next fence and the pointer.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ExecutionAttempts
  alias Opus.ExecutionRecord

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Sanctum.TestContext.athanor!()
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  test "a lapsed attempt under a foreign runner is swept, refused, and succeeded", %{ctx: ctx} do
    record =
      ExecutionRecord.new(ctx, "catalyst:local.test:1.0.0", %{"x" => 1},
        component_type: :catalyst
      )

    :ok = ExecutionRecord.write_started(record)

    {1, _} =
      Arca.Repo.update_all(
        from(a in Arca.Schemas.ExecutionAttempt, where: a.attempt == ^record.attempt),
        set: [
          runner_id: "boot-that-died",
          lease_until: DateTime.add(DateTime.utc_now(), -5, :second)
        ]
      )

    :ok = Opus.ExecutionSweeper.sweep()

    assert %{state: "lapsed", outcome: "uncertain"} =
             ExecutionAttempts.get(ctx.athanor_id, record.attempt)

    assert %{status: "failed"} = Arca.Repo.get!(Arca.Execution, record.id)

    # The dead runner's result arrives late and is refused by the fence.
    assert {:error, :not_running} =
             ExecutionRecord.write_completed(ExecutionRecord.complete(record, %{"late" => true}))

    assert %{status: "failed", output: nil} = Arca.Repo.get!(Arca.Execution, record.id)

    {:ok, %{attempt: successor}} =
      ExecutionAttempts.takeover(ctx.athanor_id, record.id,
        runner_id: ExecutionRecord.runner_id(),
        lease_until: ExecutionRecord.lease_until()
      )

    assert successor.fence == 2
    assert Arca.Repo.get!(Arca.Execution, record.id).current_attempt == successor.attempt
    assert :lost = ExecutionRecord.renew_lease(record.id, record.attempt)
    assert {:ok, _} = ExecutionRecord.renew_lease(record.id, successor.attempt)
  end

  test "a completion closes the attempt with the row, and a cancel from a read-back record closes the current one",
       %{ctx: ctx} do
    record = ExecutionRecord.new(ctx, "catalyst:local.test:1.0.0", %{}, component_type: :catalyst)
    :ok = ExecutionRecord.write_started(record)

    assert :ok =
             ExecutionRecord.write_completed(ExecutionRecord.complete(record, %{"ok" => true}))

    assert %{state: "completed", outcome: "ok"} =
             ExecutionAttempts.get(ctx.athanor_id, record.attempt)

    other = ExecutionRecord.new(ctx, "catalyst:local.test:1.0.0", %{}, component_type: :catalyst)
    :ok = ExecutionRecord.write_started(other)
    {:ok, read_back} = ExecutionRecord.get(ctx, other.id)
    assert read_back.attempt == other.attempt
    assert {:ok, %{status: :cancelled}} = ExecutionRecord.cancel(ctx, other.id)

    assert %{state: "cancelled", outcome: "cancelled"} =
             ExecutionAttempts.get(ctx.athanor_id, other.attempt)

    assert {:error, :not_cancellable} = ExecutionRecord.cancel(ctx, other.id)
  end
end
