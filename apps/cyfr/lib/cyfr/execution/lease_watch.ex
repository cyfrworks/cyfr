# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.LeaseWatch do
  @moduledoc """
  The lease keeper of an execution held outside the engine — an outbound
  tool call in flight: a process linked to the holder that renews the
  attempt's lease every tick and exits the holder when the lease is
  lost.

  A caller blocked in a call cannot service a timer of its own, so the
  keeper is a linked sibling with the rule the engine's watch applies: a
  renewal the store refuses stops the holder at once
  (`{:lease_lost, execution_id}`); a cancel asked of the attempt stops it
  at once (`{:cancel_requested, execution_id}`); a store that cannot
  answer is tolerated only inside the lease the attempt last held.
  """

  @tick_ms 60_000

  @doc """
  Start a keeper for `attempt` of `execution_id`, linked to `holder`.
  `opts`: `:tick_ms` (the renewal period), `:until` (the lease the
  attempt holds now).
  """
  @spec start(pid(), String.t(), String.t(), keyword()) :: {:ok, pid()}
  def start(holder, execution_id, attempt, opts \\ [])
      when is_pid(holder) and is_binary(execution_id) and is_binary(attempt) do
    tick = Keyword.get(opts, :tick_ms, @tick_ms)
    until = Keyword.get(opts, :until) || Arca.ExecutionAttempts.lease_until()

    pid =
      spawn_link(fn ->
        Process.link(holder)
        loop(holder, execution_id, attempt, tick, until)
      end)

    {:ok, pid}
  end

  @doc "Stop a keeper without touching its holder."
  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(pid) when is_pid(pid) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    :ok
  end

  defp loop(holder, execution_id, attempt, tick, until) do
    Process.sleep(tick)

    case Arca.ExecutionAttempts.renew(attempt, Arca.ExecutionAttempts.lease_until()) do
      {:ok, renewed, false} ->
        loop(holder, execution_id, attempt, tick, renewed)

      {:ok, _renewed, true} ->
        Process.exit(holder, {:cancel_requested, execution_id})

      :lost ->
        Process.exit(holder, {:lease_lost, execution_id})

      :unavailable ->
        if DateTime.compare(DateTime.utc_now(), until) == :lt,
          do: loop(holder, execution_id, attempt, tick, until),
          else: Process.exit(holder, {:lease_lost, execution_id})
    end
  end
end
