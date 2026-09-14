# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ExecutorCancelPenaltyTest do
  # N cancels of a spinning guest, through the executor's own cancel path,
  # charge the tenant by execution before each kill until the penalty box
  # refuses the tenant's next root.
  use ExUnit.Case, async: false

  alias Arca.Execution
  alias Cyfr.Execution.Semaphore
  alias Opus.Executor

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    ctx = Sanctum.TestContext.local()

    # The penalty box outlives a force-release: what this suite fills for
    # its tenant, it empties.
    on_exit(fn ->
      Semaphore.force_release_all()
      Semaphore.forgive_unreaped(ctx.athanor_id)
    end)

    {:ok, ctx: ctx}
  end

  defp running!(ctx) do
    id = "exec_spin_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Execution.record_start(%{
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

  # A registered runner that never yields: what a guest spinning in native
  # code looks like to the cancel path.
  defp spinning!(execution_id) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(Cyfr.Execution.Registry, execution_id, :running)
        send(parent, {:registered, execution_id})
        Process.sleep(:infinity)
      end)

    assert_receive {:registered, ^execution_id}
    pid
  end

  test "N cancels through the executor trip the tenant's penalty box", %{ctx: ctx} do
    threshold = max(2, div(Semaphore.status().tenant_max, 2))

    for _ <- 1..threshold do
      id = running!(ctx)
      pid = spinning!(id)
      ref = Process.monitor(pid)

      assert {:ok, %{cancelled: true, execution_id: ^id}} = Executor.cancel(ctx, id)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    end

    assert {:error, :tenant_unreaped_limit} =
             Semaphore.acquire(1_000, :root, ctx.athanor_id)
  end
end
