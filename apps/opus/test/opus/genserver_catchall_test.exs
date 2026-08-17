# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.GenServerCatchallTest do
  @moduledoc """
  Verifies that GenServers in the opus app survive unexpected messages
  via their catch-all `handle_info/2` clause and log a warning.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog


  describe "RateLimiter catch-all" do
    test "survives unexpected message and logs warning" do
      {:ok, pid} = GenServer.start_link(Opus.RateLimiter, [], [])

      assert capture_log(fn ->
               send(pid, :unexpected_test_message)
               :sys.get_state(pid)
             end) =~ "unexpected message"

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "survives unexpected tuple message" do
      {:ok, pid} = GenServer.start_link(Opus.RateLimiter, [], [])

      assert capture_log(fn ->
               send(pid, {:weird, "data", 42})
               :sys.get_state(pid)
             end) =~ "unexpected message"

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "ExecutionSemaphore catch-all" do
    test "survives unexpected message and logs warning" do
      {:ok, pid} = GenServer.start_link(Opus.ExecutionSemaphore, {10, 16}, [])

      assert capture_log(fn ->
               send(pid, :unexpected_test_message)
               :sys.get_state(pid)
             end) =~ "unexpected message"

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "survives unexpected tuple message" do
      {:ok, pid} = GenServer.start_link(Opus.ExecutionSemaphore, {10, 16}, [])

      assert capture_log(fn ->
               send(pid, {:bogus, :info, 123})
               :sys.get_state(pid)
             end) =~ "unexpected message"

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "ExecutionEventBuffer catch-all" do
    test "survives unexpected message and logs warning" do
      {:ok, pid} = GenServer.start_link(Opus.ExecutionEventBuffer, {"test_exec", ""}, [])

      assert capture_log(fn ->
               send(pid, :unexpected_test_message)
               :sys.get_state(pid)
             end) =~ "unexpected message"

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "survives unexpected tuple message" do
      {:ok, pid} = GenServer.start_link(Opus.ExecutionEventBuffer, {"test_exec_2", ""}, [])

      assert capture_log(fn ->
               send(pid, {:random, "payload"})
               :sys.get_state(pid)
             end) =~ "unexpected message"

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "CronScheduler catch-all" do
    test "survives unexpected message and logs warning" do
      # CronScheduler is a singleton that loads schedules from the DB on init.
      # Start a raw GenServer without the name to avoid conflicts with the
      # supervised instance and DB dependency.
      # Since init triggers :load_schedules via handle_continue, which hits
      # the database, we test against the running singleton if available.
      case Process.whereis(Opus.CronScheduler) do
        nil ->
          # Singleton not running (e.g. standalone test run) — skip gracefully
          :ok

        pid ->
          assert capture_log(fn ->
                   send(pid, :unexpected_test_message)
                   :sys.get_state(pid)
                 end) =~ "unexpected message"

          assert Process.alive?(pid)
      end
    end
  end

  describe "AsyncTracker catch-all" do
    test "survives unexpected message and logs warning" do
      {:ok, pid} = Opus.AsyncTracker.start_link(parent_execution_id: "test_catchall")

      assert capture_log(fn ->
               send(pid, :unexpected_test_message)
               :sys.get_state(pid)
             end) =~ "unexpected message"

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "survives unexpected tuple message" do
      {:ok, pid} =
        Opus.AsyncTracker.start_link(parent_execution_id: "test_catchall_2", max_tasks: 5)

      assert capture_log(fn ->
               send(pid, {:something, :entirely, :unexpected})
               :sys.get_state(pid)
             end) =~ "unexpected message"

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end
end
