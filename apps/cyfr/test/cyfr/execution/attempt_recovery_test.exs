# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.AttemptRecoveryTest do
  @moduledoc """
  A runner that died mid-execution leaves an attempt whose lease lapses:
  the sweeper retires it and fails the row, its late result is refused by
  the fence, and a successor opens with the next fence and the pointer.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ExecutionAttempts
  alias Cyfr.Execution.Record

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Sanctum.TestContext.athanor!()
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  test "a lapsed attempt under a foreign runner is swept, refused, and succeeded", %{ctx: ctx} do
    record =
      Record.new(ctx, "catalyst:local.test:1.0.0", %{"x" => 1}, component_type: :catalyst)

    :ok = Record.write_started(record)

    {1, _} =
      Arca.Repo.update_all(
        from(a in Arca.Schemas.ExecutionAttempt, where: a.attempt == ^record.attempt),
        set: [
          boot_id: "boot-that-died",
          lease_until: DateTime.add(DateTime.utc_now(), -5, :second)
        ]
      )

    :ok = Cyfr.Execution.Sweeper.sweep()

    assert %{state: "lapsed", outcome: "uncertain"} =
             ExecutionAttempts.get(ctx.athanor_id, record.attempt)

    assert %{status: "failed"} = Arca.Repo.get!(Arca.Execution, record.id)

    # The dead runner's result arrives late and is refused by the fence.
    assert {:error, :not_running} =
             Record.write_completed(Record.complete(record, %{"late" => true}))

    assert %{status: "failed", output: nil} = Arca.Repo.get!(Arca.Execution, record.id)

    {:ok, %{attempt: successor}} =
      ExecutionAttempts.takeover(ctx.athanor_id, record.id,
        boot_id: Record.boot_id(),
        lease_until: Record.lease_until()
      )

    assert successor.fence == 2
    assert Arca.Repo.get!(Arca.Execution, record.id).current_attempt == successor.attempt
    assert :lost = Record.renew_lease(record.id, record.attempt)
    assert {:ok, _} = Record.renew_lease(record.id, successor.attempt)
  end

  test "the sweep tick of a boot that does not own the control plane marks nothing", %{ctx: ctx} do
    record =
      Record.new(ctx, "catalyst:local.test:1.0.0", %{"x" => 1}, component_type: :catalyst)

    :ok = Record.write_started(record)

    {1, _} =
      Arca.Repo.update_all(
        from(a in Arca.Schemas.ExecutionAttempt, where: a.attempt == ^record.attempt),
        set: [
          boot_id: "boot-that-died",
          lease_until: DateTime.add(DateTime.utc_now(), -5, :second)
        ]
      )

    Cyfr.ControlPlane.mark(:lost)
    on_exit(fn -> Cyfr.ControlPlane.mark(:unclaimed) end)

    assert {:noreply, %{}} = Cyfr.Execution.Sweeper.handle_info(:sweep, %{})
    assert %{status: "running"} = Arca.Repo.get!(Arca.Execution, record.id)

    Cyfr.ControlPlane.mark(:unclaimed)
    assert {:noreply, %{}} = Cyfr.Execution.Sweeper.handle_info(:sweep, %{})
    assert %{status: "failed"} = Arca.Repo.get!(Arca.Execution, record.id)
  end

  test "a completion closes the attempt with the row, and a cancel from a read-back record closes the current one",
       %{ctx: ctx} do
    record = Record.new(ctx, "catalyst:local.test:1.0.0", %{}, component_type: :catalyst)
    :ok = Record.write_started(record)

    assert :ok =
             Record.write_completed(Record.complete(record, %{"ok" => true}))

    assert %{state: "completed", outcome: "ok"} =
             ExecutionAttempts.get(ctx.athanor_id, record.attempt)

    other = Record.new(ctx, "catalyst:local.test:1.0.0", %{}, component_type: :catalyst)
    :ok = Record.write_started(other)
    {:ok, read_back} = Record.get(ctx, other.id)
    assert read_back.attempt == other.attempt
    assert {:ok, %{status: :cancelled}} = Record.cancel(ctx, other.id)

    assert %{state: "cancelled", outcome: "cancelled"} =
             ExecutionAttempts.get(ctx.athanor_id, other.attempt)

    assert {:error, :not_cancellable} = Record.cancel(ctx, other.id)
  end
end
