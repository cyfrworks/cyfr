# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.SeedOffer do
  @moduledoc """
  The boot's seed offer: a new release may ship new seed media (bundle
  versions, a new AQUA template), and boot is when the athanors that
  already exist are offered it — additively, never over anything they own
  (`Compendium.sync_seeds/0`).

  Optional work, and never a gate. It starts after `Cyfr.Bootstrap`'s
  checked success, last in the infra tier and before the web tier that
  holds the endpoint, and its start returns at once: the offer runs after `init/1`, so the infra tier
  finishes and the endpoint starts without waiting for it. A person who
  signs in while it runs finds the athanor claim the sync holds, and their
  fill is skipped rather than waited for; the next sign-in or the next
  boot tries again. Nothing that goes wrong here stops the boot, and the
  server is temporary, so a failed offer restarts nothing.

  The offer is the cell's, not each member's: it runs under the
  `seed_release` claim (`Arca.JobClaims`, key `"cell"`), and a member
  that finds a live peer holding it does not wait — the rows it writes are
  shared, so one member doing it covers the rest.

  The work runs in a task linked to this server, which renews the claim
  at a third of its lease while the task runs and carries the fence each
  renewal answers. The claim is given back only once the task is dead,
  whichever way the offer ends: the work done or raised, the task killed,
  a renewal lost (the task is stopped first) or this server shut down
  (`terminate/2` stops the task first). A server killed outright takes
  the task with it through the link, and the claim is left to its lease.

  The server stops with `{:shutdown, outcome}`: `:ok`, `:skipped` when a
  live peer holds the claim, or `{:error, reason}` — `:database_error`
  when the claim could not be read, `:exception` when the work raised,
  `:died` when its task died without answering, `:claim_lost` when a
  renewal did not land. An offer that ran ends in
  `[:cyfr, :seed_offer, :completed]`, and one that took the claim or tried
  to and did not finish in `[:cyfr, :seed_offer, :aborted]` with its
  `reason` (`:shutdown` for a stop from the supervisor). A peer's offer
  emits neither.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Arca.JobClaims

  @lease_ms :timer.minutes(5)

  @type outcome ::
          :ok | :skipped | {:error, :database_error | :exception | :died | :claim_lost}

  @doc """
  Start the offer; it runs once `start_link/1` has returned.

  `opts`: `:key` (`"cell"` by default), `:owner` (this boot by default),
  `:lease_ms`, and `:sync`, the work itself, which the composition root
  names (`Compendium.sync_seeds/0`): the host names no domain.
  """
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    # The claim is released only once the task is dead, and the task is
    # linked: trapping exits keeps a task's death a message here, and makes
    # a stop from the supervisor run `terminate/2`, which stops it.
    Process.flag(:trap_exit, true)

    state = %{
      key: Keyword.get(opts, :key, JobClaims.cell_key()),
      owner: Keyword.get(opts, :owner, Prima.Boot.id()),
      lease_ms: Keyword.get(opts, :lease_ms, @lease_ms),
      sync: Keyword.fetch!(opts, :sync),
      claim: nil,
      task: nil,
      timer: nil,
      answer: nil,
      began: nil
    }

    {:ok, state, {:continue, :offer}}
  end

  @impl true
  def handle_continue(:offer, state) do
    case JobClaims.claim("seed_release", state.key, state.owner, state.lease_ms) do
      {:ok, claim} ->
        began = System.monotonic_time()
        task = Task.async(fn -> offer(state.sync) end)
        {:noreply, renew_later(%{state | claim: claim, task: task, began: began})}

      {:busy, %{owner: peer}} ->
        Logger.info("[Cyfr.SeedOffer] the seed offer is #{peer}'s this boot")
        {:stop, {:shutdown, :skipped}, state}

      {:error, :database_error} ->
        Logger.error("[Cyfr.SeedOffer] the seed_release claim could not be read; skipping")
        aborted(state, :database_error)
        {:stop, {:shutdown, {:error, :database_error}}, state}
    end
  end

  @impl true
  # The task's answer arrives before its death; the claim waits for the
  # death.
  def handle_info({ref, answer}, %{task: %Task{ref: ref}} = state),
    do: {:noreply, %{state | answer: answer}}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    outcome = state.answer || died(reason)
    stop(%{state | task: nil}, outcome)
  end

  def handle_info(:renew, %{task: %Task{}} = state) do
    case JobClaims.renew(state.claim, state.lease_ms) do
      {:ok, claim} ->
        # The renewal raised the fence: the claim this server answers for,
        # and gives back, is the row it wrote.
        {:noreply, renew_later(%{state | claim: claim})}

      lost ->
        # The work may no longer write under this claim: it is stopped
        # first, and only then is the claim given up — unless a peer holds
        # it, when there is nothing of this server's left to give.
        Logger.error("[Cyfr.SeedOffer] the seed_release claim was not renewed (#{lost(lost)})")
        state = stop_task(%{state | timer: nil})
        state = if lost == :taken, do: %{state | claim: nil}, else: state
        stop(state, state.answer || {:error, :claim_lost})
    end
  end

  # The task's link: its monitor is what decides.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  @impl true
  # A stop from the supervisor while the offer runs. The stops this server
  # makes itself have already given the claim up and left it `nil`.
  def terminate(_reason, %{claim: claim} = state) when claim != nil do
    state |> stop_task() |> cleanup()
    aborted(state, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ---- internal --------------------------------------------------------------

  # Run inside the task. Nothing is printed from an exception but its
  # module, and the task answers rather than crashing, so a failure
  # carries no crash report.
  defp offer(sync) do
    sync.()
    :ok
  rescue
    e ->
      Logger.error("[Cyfr.SeedOffer] seed offer failed: #{inspect(e.__struct__)}")
      {:error, :exception}
  catch
    kind, _reason ->
      Logger.error("[Cyfr.SeedOffer] seed offer failed: #{kind}")
      {:error, :exception}
  end

  # Every stop this server makes once the task is dead: the timer, then the
  # claim, then the event, and the claim is forgotten so `terminate/2`
  # gives nothing back twice.
  defp stop(%{task: nil} = state, outcome) do
    cleanup(state)

    case outcome do
      :ok ->
        :telemetry.execute(
          [:cyfr, :seed_offer, :completed],
          %{duration: System.monotonic_time() - state.began},
          %{key: state.key}
        )

      {:error, reason} ->
        aborted(state, reason)
    end

    {:stop, {:shutdown, outcome}, %{state | claim: nil, timer: nil}}
  end

  defp aborted(state, reason) do
    :telemetry.execute([:cyfr, :seed_offer, :aborted], %{duration: elapsed(state)}, %{
      key: state.key,
      reason: reason
    })
  end

  defp elapsed(%{began: nil}), do: 0
  defp elapsed(%{began: began}), do: System.monotonic_time() - began

  defp died(reason) do
    Logger.error("[Cyfr.SeedOffer] the seed offer's task died: #{died_class(reason)}")
    {:error, :died}
  end

  defp died_class(reason) when is_atom(reason), do: inspect(reason)
  defp died_class(_reason), do: "exit"

  defp lost(:taken), do: "taken"
  defp lost(:lapsed), do: "lapsed"
  defp lost({:error, :database_error}), do: "unreadable"

  # A third of the lease, so a renewal held up behind a slow store still
  # lands while the lease stands; one that does not land ends the offer.
  defp renew_later(state),
    do: %{state | timer: Process.send_after(self(), :renew, max(div(state.lease_ms, 3), 1))}

  # `Task.shutdown/2` with `:brutal_kill` returns only once the task's
  # monitor has fired: the task is dead when it returns. An answer it sent
  # first is kept.
  defp stop_task(%{task: %Task{} = task} = state) do
    case Task.shutdown(task, :brutal_kill) do
      {:ok, answer} -> %{state | task: nil, answer: answer}
      _dead -> %{state | task: nil}
    end
  end

  defp stop_task(state), do: state

  defp cleanup(%{task: nil} = state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    if state.claim, do: release(state.claim)
    :ok
  end

  defp release(claim) do
    case JobClaims.release(claim) do
      :ok ->
        :ok

      other ->
        Logger.warning(
          "[Cyfr.SeedOffer] the seed_release claim was not given back (#{inspect(other)}); " <>
            "it is left to its lease"
        )
    end
  end
end
