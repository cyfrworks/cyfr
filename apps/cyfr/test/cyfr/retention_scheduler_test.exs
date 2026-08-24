# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RetentionSchedulerTest do
  use ExUnit.Case, async: false

  alias Cyfr.RetentionScheduler

  setup do
    # Ensure no lingering scheduler
    case GenServer.whereis(RetentionScheduler) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    # handle_continue(:first_run, ...) calls run_cleanup() which hits the DB
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    :ok
  end

  describe "init/1" do
    test "starts with {:continue, :first_run}" do
      prev_interval = Application.get_env(:cyfr, :retention_scheduler_interval)

      # Use a very long interval to avoid actual cleanup during test
      Application.put_env(:cyfr, :retention_scheduler_interval, :timer.hours(999))

      on_exit(fn ->
        if prev_interval,
          do: Application.put_env(:cyfr, :retention_scheduler_interval, prev_interval),
          else: Application.delete_env(:cyfr, :retention_scheduler_interval)
      end)

      assert {:ok, %{interval: _}, {:continue, :first_run}} = RetentionScheduler.init([])
    end
  end

  describe "handle_continue/2" do
    test "returns {:noreply, state}" do
      state = %{interval: :timer.hours(999)}
      assert {:noreply, ^state} = RetentionScheduler.handle_continue(:first_run, state)
    end
  end

  describe "handle_info/2" do
    test "handles unexpected messages gracefully" do
      state = %{interval: :timer.hours(6)}
      assert {:noreply, ^state} = RetentionScheduler.handle_info(:unexpected, state)
    end
  end
end
