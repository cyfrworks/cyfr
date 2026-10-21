# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.LeaseWatch do
  @moduledoc """
  The lease keeper of an execution held outside the engine — a turn root
  (`Opus.TurnRoot`) or an outbound tool call in flight: a
  process that watches the holder, renews the attempt's lease every tick
  and exits the holder when the lease is lost.

  A caller blocked in a call cannot service a timer of its own, so the
  keeper is a linked sibling that renews through
  `Opus.Record.renew_lease/2`: a renewal the store refuses,
  a cancelled row's included, stops the holder at once
  (`{:lease_lost, execution_id}`); a store that cannot answer, a renewal
  that raises included, decides nothing, and the keeper renews again a
  tick later. The lease is the cell's (`Opus.Record.lease_until/0`), and
  this member's clock is never set against it: as the sweeper does, a
  lease decision waits for a store that answers. A lease that lapsed in
  the outage is lapsed by a sweeper that reads the store, and the next
  renewal that reaches it answers `:lost`.

  The holder is the process that starts the keeper. The keeper is linked
  to it, so a crash of either takes the other down at once, and monitors
  it, so a holder that ends without stopping it, normally included, ends
  it too. It makes no link once it runs: `stop/1` drops the holder's link
  before it kills the keeper, and a link made after that would carry the
  kill to the holder.

  A holder that moves the attempt out of `running` suspends its keeper
  first (`suspend/1`), so no renewal races the move, and then stops it
  (`stop/1`), or resumes it (`resume/1`) when the move did not happen. The
  keeper keeps its pid throughout.
  """

  alias Opus.Record

  @tick_ms 60_000

  @doc """
  Start a keeper for `attempt` of `execution_id`, held by the calling
  process. `opts`: `:tick_ms` (the renewal period).
  """
  @spec start(String.t(), String.t(), keyword()) :: {:ok, pid()}
  def start(execution_id, attempt, opts \\ [])
      when is_binary(execution_id) and is_binary(attempt) do
    holder = self()

    watch = %{
      holder: holder,
      execution_id: execution_id,
      attempt: attempt,
      tick: Keyword.get(opts, :tick_ms, @tick_ms)
    }

    pid = spawn_link(fn -> loop(Map.put(watch, :down, Process.monitor(holder))) end)

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

  @doc "Stop a keeper from its holder, without touching the holder."
  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    :ok
  end

  # A holder that ends ends its keeper, suspended or not.
  defp loop(%{down: down} = watch) do
    receive do
      {:suspend, from, ref} ->
        send(from, {ref, :suspended})
        suspended(watch)

      {:DOWN, ^down, :process, _, _} ->
        :ok
    after
      watch.tick -> renew(watch)
    end
  end

  defp suspended(%{down: down} = watch) do
    receive do
      :resume -> loop(watch)
      {:DOWN, ^down, :process, _, _} -> :ok
    end
  end

  defp renew(%{holder: holder, execution_id: execution_id} = watch) do
    case Record.renew_lease(execution_id, watch.attempt) do
      {:ok, _renewed} -> loop(watch)
      :lost -> Process.exit(holder, {:lease_lost, execution_id})
      :unavailable -> loop(watch)
    end
  end
end
