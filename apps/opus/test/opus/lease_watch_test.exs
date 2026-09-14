# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.LeaseWatchTest do
  # A renewal the store refuses stops the runner on the first answer; a
  # renewal the store cannot answer is tolerated only inside the lease the
  # attempt last held.
  use ExUnit.Case, async: false

  alias Arca.Execution
  alias Cyfr.Execution.Record
  alias Opus.Executor

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp running!(attempt) do
    id = "exec_watch_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Execution.admit(
        %{
          id: id,
          reference: "catalyst:local.test:1.0.0",
          user_id: "user_test",
          athanor_id: Sanctum.TestContext.athanor_id(),
          component_type: "catalyst"
        },
        attempt: attempt,
        runner_id: Record.runner_id()
      )

    id
  end

  defp watch(id, attempt, until) do
    %{execution_id: id, attempt: attempt, tenant: Sanctum.TestContext.athanor_id(), until: until}
  end

  defp far, do: DateTime.add(DateTime.utc_now(), 3600, :second)

  test "a renewal the store refuses lapses the watch at once, inside the lease last held" do
    id = running!("att_1")

    assert {:ok, %{until: renewed}} = Executor.renew_watch(watch(id, "att_1", far()))
    assert DateTime.compare(renewed, DateTime.utc_now()) == :gt

    {:ok, _} =
      Execution.record_end(
        Sanctum.TestContext.local(),
        id,
        "completed",
        %{completed_at: DateTime.utc_now(), duration_ms: 1},
        "att_1"
      )

    assert :lost = Record.renew_lease(id, "att_1")
    assert :lapsed = Executor.renew_watch(watch(id, "att_1", far()))
  end

  test "a cancel asked of the attempt reaches the watch at its next tick" do
    id = running!("att_c")
    {:ok, 1} = Arca.ExecutionAttempts.request_cancel(Sanctum.TestContext.athanor_id(), id)
    assert {:cancel_requested, _} = Record.renew_lease(id, "att_c")
    assert :cancelled = Executor.renew_watch(watch(id, "att_c", far()))
  end

  test "another attempt's renewal is refused, not tolerated" do
    id = running!("att_1")

    assert :lost = Record.renew_lease(id, "att_2")
    assert :lapsed = Executor.renew_watch(watch(id, "att_2", far()))
  end

  test "a store that cannot answer is tolerated only while the lease last held holds" do
    id = running!("att_1")
    drop_executions!()

    assert :unavailable = Record.renew_lease(id, "att_1")

    now = DateTime.utc_now()
    inside = watch(id, "att_1", DateTime.add(now, 60, :second))
    assert {:ok, ^inside} = Executor.renew_watch(inside, now)

    past = watch(id, "att_1", DateTime.add(now, -1, :second))
    assert :lapsed = Executor.renew_watch(past, now)
  end

  # An outage, simulated: the table is gone. Postgres drops the tables that
  # reference `executions` along with it.
  defp drop_executions! do
    if Cyfr.RuntimeConfig.repo_adapter() == Ecto.Adapters.Postgres,
      do: Arca.Repo.query!("DROP TABLE executions CASCADE"),
      else: Arca.Repo.query!("DROP TABLE executions")
  end
end
