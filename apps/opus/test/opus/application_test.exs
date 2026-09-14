# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ApplicationTest do
  use ExUnit.Case, async: false

  describe "supervisor tree" do
    test "Opus.Supervisor supervises the engine's own processes" do
      assert Process.whereis(Opus.Supervisor) != nil

      ids = for {id, _pid, _type, _modules} <- Supervisor.which_children(Opus.Supervisor), do: id

      for id <- [
            Opus.SharedEngine,
            Opus.TaskSupervisor,
            Opus.ExecutionSweeper,
            Opus.OAuthTokenTracker
          ] do
        assert id in ids, "#{inspect(id)} is not a child of Opus.Supervisor"
      end
    end

    test "the execution slots, rates and event streams are cyfr's, not the engine's" do
      ids = for {id, _pid, _type, _modules} <- Supervisor.which_children(Opus.Supervisor), do: id

      for id <- [Cyfr.Execution.Rates, Cyfr.Execution.Semaphore, Cyfr.Execution.Tree] do
        refute id in ids, "#{inspect(id)} is supervised by opus"
        assert Process.whereis(id) != nil, "#{inspect(id)} is not running"
      end
    end
  end

  describe "readiness" do
    test "the engine is ready once the execution slots and its WASM engine are up" do
      assert Opus.ready?()
      assert Cyfr.Execution.available?()
    end
  end
end
