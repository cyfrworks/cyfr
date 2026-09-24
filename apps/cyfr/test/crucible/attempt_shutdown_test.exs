# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.AttemptShutdownTest do
  @moduledoc """
  An attempt stopped by its supervisor finishes its reaction to a waiter
  that is gone, even when the waiter's exit arrived and was not yet
  handled: its runner is killed through its worker service, over the
  wire, and its row lapses. An attempt stopped while its waiter lives
  leaves the run to the waiter.
  """

  use ExUnit.Case, async: false

  import Prima.Test.Wait

  alias Crucible.Attempt
  alias Prima.Slots
  alias Cyfr.Test.{AttemptFixtures, ScriptedWorkerListener}

  @service "wrk_shutdown_test"
  @lapsed "Execution terminated: runner stopped without cleanup"
  @slots Crucible.Slots
  @unreaped_kill [:cyfr, :opus, :execution, :unreaped_kill]

  # A worker service that records the kills it is asked for, served over
  # HTTP by the scripted listener as any worker service is.
  defmodule KillRecorder do
    @moduledoc false
    @behaviour Prima.WorkerAPI

    @impl true
    def start(_token, _input, _sealed_keys), do: {:error, :malformed}

    @impl true
    def kill(execution_id) do
      send(Crucible.AttemptShutdownTest, {:killed, execution_id})
      :ok
    end

    @impl true
    def status,
      do:
        {:ok,
         %{
           service: "wrk_shutdown_test",
           boot: "worker_shutdown_test",
           runners: %{fresh: 0, idle: 0, busy: 0},
           attempts: []
         }}
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Process.register(self(), __MODULE__)

    handler = "unreaped-kill-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler, @unreaped_kill, &__MODULE__.forward_event/4, self())

    on_exit(fn ->
      :telemetry.detach(handler)
      Slots.forgive_unreaped(@slots, Sanctum.TestContext.local().athanor_id)
    end)

    listener =
      start_supervised!({ScriptedWorkerListener, worker: KillRecorder, service: @service})

    {:ok, endpoint: ScriptedWorkerListener.endpoint(listener, @service)}
  end

  @doc false
  def forward_event(event, measurements, metadata, test),
    do: send(test, {:telemetry, event, measurements, metadata})

  # An attached attempt opened by a process of its own, which exits when
  # told to.
  defp opened_by_waiter!(endpoint) do
    test = self()

    waiter =
      spawn(fn ->
        fixture = AttemptFixtures.attached!(service_id: @service, worker: endpoint)
        send(test, {:opened, fixture})
        receive do: (:exit -> :ok)
      end)

    assert_receive {:opened, fixture}, 5_000
    {waiter, fixture}
  end

  defp row(fixture), do: Arca.Repo.get!(Arca.Schemas.Execution, fixture.execution_id)

  test "a stop after the waiter exited, before its exit was handled, kills the runner and lapses the row",
       %{endpoint: endpoint} do
    {waiter, fixture} = opened_by_waiter!(endpoint)

    # The waiter's exit reaches the attempt while it handles nothing.
    :ok = :sys.suspend(fixture.pid)
    ref = Process.monitor(waiter)
    send(waiter, :exit)
    assert_receive {:DOWN, ^ref, :process, ^waiter, _reason}

    :ok = DynamicSupervisor.terminate_child(Attempt.Supervisor, fixture.pid)

    id = fixture.execution_id
    assert_receive {:killed, ^id}, 5_000
    refute Process.alive?(fixture.pid)
    assert %{status: "failed", error_message: @lapsed} = row(fixture)

    assert %{state: "lapsed", outcome: "uncertain"} =
             Arca.ExecutionAttempts.get(
               Prima.Actor.in_athanor(fixture.athanor_id),
               fixture.attempt
             )

    # The kill of a runner that had attached is counted against the
    # athanor's execution slots, and said with the athanor's live count.
    tenant = fixture.athanor_id

    assert_receive {:telemetry, @unreaped_kill, %{unreaped_count: count},
                    %{tenant: ^tenant, execution_id: ^id}},
                   5_000

    assert count >= 1
    assert Map.get(Slots.status(@slots).unreaped, tenant, 0) == count
  end

  test "a stop while the waiter lives kills nothing and leaves the row to the waiter", %{
    endpoint: endpoint
  } do
    {waiter, fixture} = opened_by_waiter!(endpoint)

    :ok = DynamicSupervisor.terminate_child(Attempt.Supervisor, fixture.pid)

    refute Process.alive?(fixture.pid)
    refute_received {:killed, _}
    refute_received {:telemetry, @unreaped_kill, _, _}
    assert %{status: "running"} = row(fixture)

    send(waiter, :exit)
    wait_until(fn -> not Process.alive?(waiter) end)
  end
end
