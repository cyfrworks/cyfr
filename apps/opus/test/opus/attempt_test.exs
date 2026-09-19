# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.AttemptTest do
  @moduledoc """
  What an exit or a throw out of a component call leaves in the run's
  error and the log: its kind, never the reason. An exit carries the call
  it ended, and a call carries what it was asked with, so a guest's input
  in either stays where it was.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Opus.Attempt

  @input ~s({"messages":[{"role":"user","content":"canary-a8c1f0 in the transcript"}]})

  test "an exit carrying the call it ended is rendered by its kind" do
    call = {GenServer, :call, [self(), {:call_function, "run", [@input]}, :infinity]}

    for {reason, kind} <- [
          {{:timeout, call}, "timeout"},
          {{:noproc, call}, "noproc"},
          {{{%RuntimeError{message: @input}, []}, call}, "exit"},
          {:killed, "killed"},
          {{@input, call}, "exit"},
          {[@input], "exit"}
        ] do
      log = capture_log(fn -> send(self(), {:error, Attempt.caught(:exit, reason)}) end)
      assert_received {:error, error}

      assert error == "Execution error: the component call ended (#{kind})"
      refute error =~ "canary"
      refute log =~ "canary"
    end
  end

  test "a throw is rendered as one, whatever it threw" do
    log = capture_log(fn -> send(self(), {:error, Attempt.caught(:throw, {:value, @input})}) end)
    assert_received {:error, "Execution error: the component call threw"}
    refute log =~ "canary"
  end
end
