# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.LeaseWatch do
  @moduledoc """
  The lease keeper of an execution held outside the engine — a turn root
  (`Cyfr.Execution.TurnRoot`) or an outbound tool call in flight: a
  process linked to the holder that renews the attempt's lease every tick
  and exits the holder when the lease is lost.

  A caller blocked in a call cannot service a timer of its own, so the
  keeper is a linked sibling with the rule the engine's watch applies
  (`Cyfr.Execution.Record.renew_lease/2`): a renewal the store refuses,
  a cancelled row's included, stops the holder at once
  (`{:lease_lost, execution_id}`); a store that cannot answer, a renewal
  that raises included, is tolerated only inside the lease the attempt
  last held.

  A holder that moves the attempt out of `running` suspends its keeper
  first (`suspend/1`), so no renewal races the move, and then stops it
  (`stop/1`), or resumes it (`resume/1`) when the move did not happen. The
  keeper keeps its pid throughout.
  """

  alias Cyfr.Execution.Record

  @tick_ms 60_000

  @doc """
  Start a keeper for `attempt` of `execution_id`, linked to `holder`.
  `opts`: `:tick_ms` (the renewal period), `:until` (the lease the
  attempt holds now).
  """
  @spec start(pid(), String.t(), String.t(), keyword()) :: {:ok, pid()}
  def start(holder, execution_id, attempt, opts \\ [])
      when is_pid(holder) and is_binary(execution_id) and is_binary(attempt) do
    watch = %{
      holder: holder,
      execution_id: execution_id,
      attempt: attempt,
      tick: Keyword.get(opts, :tick_ms, @tick_ms)
    }

    until = Keyword.get(opts, :until) || Record.lease_until()

    pid =
      spawn_link(fn ->
        Process.link(holder)
        loop(watch, until)
      end)

    {:ok, pid}
  end

  @doc """
  Stop renewing until `resume/1`. Answers once the keeper will renew
  nothing more; a renewal in flight finishes first. A keeper that is gone
  answers `:ok` too.
  """
  @spec suspend(pid()) :: :ok
  def suspend(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    send(pid, {:suspend, self(), ref})

    receive do
      {^ref, :suspended} -> Process.demonitor(ref, [:flush])
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end

    :ok
  end

  @doc "Renew again, a tick from now, after `suspend/1`."
  @spec resume(pid()) :: :ok
  def resume(pid) when is_pid(pid) do
    send(pid, :resume)
    :ok
  end

  @doc "Stop a keeper without touching its holder."
  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(pid) when is_pid(pid) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    :ok
  end

  defp loop(watch, until) do
    receive do
      {:suspend, from, ref} ->
        send(from, {ref, :suspended})
        receive do: (:resume -> loop(watch, until))
    after
      watch.tick -> renew(watch, until)
    end
  end

  defp renew(%{holder: holder, execution_id: execution_id} = watch, until) do
    case Record.renew_lease(execution_id, watch.attempt) do
      {:ok, renewed} ->
        loop(watch, renewed)

      :lost ->
        Process.exit(holder, {:lease_lost, execution_id})

      :unavailable ->
        if DateTime.compare(DateTime.utc_now(), until) == :lt,
          do: loop(watch, until),
          else: Process.exit(holder, {:lease_lost, execution_id})
    end
  end
end
