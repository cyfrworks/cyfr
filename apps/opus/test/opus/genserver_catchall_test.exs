# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.GenServerCatchallTest do
  @moduledoc """
  Verifies that GenServers in the opus app survive unexpected messages
  via their catch-all `handle_info/2` clause and log a warning.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  describe "WorkerService catch-all" do
    test "survives an unexpected message and logs it" do
      pid = Process.whereis(Opus.WorkerService)

      assert capture_log(fn ->
               send(pid, {:something, :entirely, :unexpected})
               :sys.get_state(pid)
             end) =~ "unexpected message"

      assert Process.whereis(Opus.WorkerService) == pid
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
