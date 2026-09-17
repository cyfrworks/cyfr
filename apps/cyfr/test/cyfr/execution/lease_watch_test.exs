# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.LeaseWatchTest do
  use ExUnit.Case, async: false

  alias Cyfr.Execution.LeaseWatch

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    ctx = Sanctum.TestContext.local()

    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(%{
        id: Cyfr.UUID7.execution_id(),
        reference: "peer:probe",
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        component_type: "tool_server",
        kind: "tool_call"
      })

    {:ok, ctx: ctx, id: execution.id, attempt: attempt.attempt}
  end

  # A holder blocked in a call, watched with a fast tick.
  defp holder!(id, attempt, opts \\ []) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, watch} = LeaseWatch.start(self(), id, attempt, [tick_ms: 20] ++ opts)
        send(parent, {:watching, watch})

        receive do
          :stop_watch ->
            :ok = LeaseWatch.stop(watch)
            receive do: (:release -> :ok)

          :release ->
            :ok
        end
      end)

    assert_receive {:watching, watch}
    {pid, ref, watch}
  end

  test "a lease the attempt no longer holds exits the holder", %{
    ctx: ctx,
    id: id,
    attempt: attempt
  } do
    {_pid, ref, _watch} = holder!(id, attempt)

    {:ok, _} =
      Arca.Execution.record_end(
        ctx,
        id,
        "failed",
        %{completed_at: DateTime.utc_now(), duration_ms: 0, error_message: "swept"},
        attempt
      )

    assert_receive {:DOWN, ^ref, :process, _, {:lease_lost, ^id}}, 2_000
  end

  # The keeper is no sandbox owner: once the shared connection is
  # withdrawn, every renewal it attempts raises.
  @tag :capture_log
  test "a renewal that raises is tolerated inside the lease the attempt last held", %{
    id: id,
    attempt: attempt
  } do
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, :manual)
    {pid, ref, _watch} = holder!(id, attempt)
    Process.sleep(100)
    refute_received {:DOWN, ^ref, :process, _, _}
    assert Process.alive?(pid)
    send(pid, :release)
  end

  @tag :capture_log
  test "a renewal that raises past the lease the attempt last held exits the holder", %{
    id: id,
    attempt: attempt
  } do
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, :manual)
    {_pid, ref, _watch} = holder!(id, attempt, until: DateTime.add(DateTime.utc_now(), -1))
    assert_receive {:DOWN, ^ref, :process, _, {:lease_lost, ^id}}, 2_000
  end

  test "a suspended keeper renews nothing until it is resumed, and keeps its pid", %{
    ctx: ctx,
    id: id,
    attempt: attempt
  } do
    {pid, ref, watch} = holder!(id, attempt)
    :ok = LeaseWatch.suspend(watch)
    %{lease_until: suspended} = Arca.ExecutionAttempts.get(ctx.athanor_id, attempt)

    Process.sleep(100)
    assert %{lease_until: ^suspended} = Arca.ExecutionAttempts.get(ctx.athanor_id, attempt)

    :ok = LeaseWatch.resume(watch)

    Cyfr.Test.Wait.wait_until(fn ->
      %{lease_until: renewed} = Arca.ExecutionAttempts.get(ctx.athanor_id, attempt)
      DateTime.compare(renewed, suspended) == :gt
    end)

    assert Process.alive?(watch)
    refute_received {:DOWN, ^ref, :process, _, _}
    send(pid, :release)
  end

  test "suspending a keeper that is gone answers at once", %{id: id, attempt: attempt} do
    {pid, _ref, watch} = holder!(id, attempt)
    send(pid, :stop_watch)
    Cyfr.Test.Wait.wait_until(fn -> not Process.alive?(watch) end)
    assert :ok = LeaseWatch.suspend(watch)
    send(pid, :release)
  end

  test "a watch its holder stopped leaves the holder alone", %{id: id, attempt: attempt} do
    {pid, ref, watch} = holder!(id, attempt)
    send(pid, :stop_watch)
    Process.sleep(100)
    refute Process.alive?(watch)
    refute_received {:DOWN, ^ref, :process, _, _}
    assert Process.alive?(pid)
    send(pid, :release)
  end
end
