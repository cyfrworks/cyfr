# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.AttemptWaiter do
  @moduledoc """
  The waiter's side of an `Opus.Attempt` a test opened as its own waiter
  (`Cyfr.Test.AttemptFixtures`): the attempt reports its run's result to
  the process that opened it, as it does to `Opus.Dispatch`'s waiter.
  """

  @doc """
  Wait, in the process that opened the attempt `pid`, for it to close its
  run, and answer the run's result: `{:ok, result}` or `{:error, reason}`
  as `Opus.Close` answered. An attempt that stops without closing its run
  is closed lost with `close` (`Opus.Close.lost/1`), as the dispatch
  waiter closes it.
  """
  @spec await(pid(), Opus.Close.t()) :: {:ok, map()} | {:error, term()}
  def await(pid, %Opus.Close{} = close) when is_pid(pid) do
    ref = Process.monitor(pid)

    receive do
      {Opus.Attempt, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        Opus.Close.lost(close)
    end
  end
end
