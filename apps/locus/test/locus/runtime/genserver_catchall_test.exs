# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.GenServerCatchallTest do
  @moduledoc """
  Verifies that the runtime's GenServers survive unexpected messages
  via their catch-all `handle_info/2` clause and log a warning.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  describe "WorkerService catch-all" do
    test "survives an unexpected message and logs it" do
      pid = Process.whereis(Locus.Runtime.WorkerService)

      assert capture_log(fn ->
               send(pid, {:something, :entirely, :unexpected})
               :sys.get_state(pid)
             end) =~ "unexpected message"

      assert Process.whereis(Locus.Runtime.WorkerService) == pid
    end
  end

  describe "AsyncTracker catch-all" do
    test "survives unexpected message and logs warning" do
      {:ok, pid} = Locus.Runtime.AsyncTracker.start_link(max_tasks: 5)

      assert capture_log(fn ->
               send(pid, :unexpected_test_message)
               :sys.get_state(pid)
             end) =~ "unexpected message"

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "survives unexpected tuple message" do
      {:ok, pid} =
        Locus.Runtime.AsyncTracker.start_link(max_tasks: 5)

      assert capture_log(fn ->
               send(pid, {:something, :entirely, :unexpected})
               :sys.get_state(pid)
             end) =~ "unexpected message"

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end
end
