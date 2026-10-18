# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.LeaseWatchTest do
  use ExUnit.Case, async: false

  alias Opus.LeaseWatch

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    ctx = Sanctum.TestContext.local(:api)

    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: Prima.UUID7.execution_id(),
          reference: "peer:probe",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "tool_server",
          kind: "tool_call",
          origin: :programmatic
        },
        Cyfr.Test.AttemptFixtures.standing(ctx.athanor_id)
      )

    {:ok, ctx: ctx, id: execution.id, attempt: attempt.attempt}
  end

  # Killed when the test ends, passing or not, and gone before the
  # cleanup registered ahead of it runs.
  defp kill_on_exit(pid) do
    on_exit(fn ->
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      end
    end)
  end

  # A holder blocked in a call, watched with a fast tick.
  defp holder!(id, attempt, opts \\ []) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, watch} = LeaseWatch.start(id, attempt, [tick_ms: 20] ++ opts)
        send(parent, {:watching, watch})

        receive do
          :stop_watch ->
            :ok = LeaseWatch.stop(watch)
            receive do: (:release -> :ok)

          :release ->
            :ok
        end
      end)

    # Unlinked, so a failed assertion would leave it waiting for a release.
    kill_on_exit(pid)
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
        Sanctum.Context.actor(ctx),
        id,
        "failed",
        %{completed_at: DateTime.utc_now(), duration_ms: 0, error_message: "swept"},
        attempt,
        Cyfr.Test.AttemptFixtures.stored()
      )

    assert_receive {:DOWN, ^ref, :process, _, {:lease_lost, ^id}}, 2_000
  end

  # The keeper is no sandbox owner: once the shared connection is
  # withdrawn, every renewal it attempts raises.
  @tag :capture_log
  test "a renewal that raises decides nothing, and the holder runs on", %{
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

  # The lease is the cell's: a member that cannot read the store sets no
  # clock of its own against it, however far past it that clock reads, as
  # the sweeper takes no lease decision on a clock it could not read. The
  # `:until` a caller hands in is a lease long past on this member's clock.
  @tag :capture_log
  test "a store that cannot answer leaves the lease undecided, past this member's clock included",
       %{id: id, attempt: attempt} do
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, :manual)
    {pid, ref, _watch} = holder!(id, attempt, until: DateTime.add(DateTime.utc_now(), -60))
    # Five renewal ticks, each refused by the store.
    Process.sleep(100)
    refute_received {:DOWN, ^ref, :process, _, _}
    assert Process.alive?(pid)
    send(pid, :release)
  end

  test "a suspended keeper renews nothing until it is resumed, and keeps its pid", %{
    ctx: ctx,
    id: id,
    attempt: attempt
  } do
    {pid, ref, watch} = holder!(id, attempt)
    :ok = LeaseWatch.suspend(watch)
    %{lease_until: suspended} = Arca.ExecutionAttempts.get(Sanctum.Context.actor(ctx), attempt)

    Process.sleep(100)

    assert %{lease_until: ^suspended} =
             Arca.ExecutionAttempts.get(Sanctum.Context.actor(ctx), attempt)

    :ok = LeaseWatch.resume(watch)

    Prima.Test.Wait.wait_until(fn ->
      %{lease_until: renewed} = Arca.ExecutionAttempts.get(Sanctum.Context.actor(ctx), attempt)
      DateTime.compare(renewed, suspended) == :gt
    end)

    assert Process.alive?(watch)
    refute_received {:DOWN, ^ref, :process, _, _}
    send(pid, :release)
  end

  test "suspending a keeper that is gone answers at once", %{id: id, attempt: attempt} do
    {pid, _ref, watch} = holder!(id, attempt)
    send(pid, :stop_watch)
    Prima.Test.Wait.wait_until(fn -> not Process.alive?(watch) end)
    assert :ok = LeaseWatch.suspend(watch)
    send(pid, :release)
  end

  test "a holder that ends without stopping its keeper, normally or not, ends the keeper", %{
    id: id,
    attempt: attempt
  } do
    for reason <- [:normal, :crashed] do
      {pid, ref, watch} = holder!(id, attempt)
      keeper = Process.monitor(watch)
      if reason == :normal, do: send(pid, :release), else: Process.exit(pid, reason)
      assert_receive {:DOWN, ^ref, :process, ^pid, ^reason}
      assert_receive {:DOWN, ^keeper, :process, ^watch, ^reason}, 2_000
    end
  end

  test "a watch its holder stopped leaves the holder alone", %{id: id, attempt: attempt} do
    {pid, ref, watch} = holder!(id, attempt)
    keeper = Process.monitor(watch)
    send(pid, :stop_watch)
    assert_receive {:DOWN, ^keeper, :process, ^watch, :killed}, 2_000
    # The keeper's exit reaches a still-linked holder alongside its DOWN.
    refute_receive {:DOWN, ^ref, :process, _, _}, 100
    assert Process.alive?(pid)
    send(pid, :release)
  end
end
