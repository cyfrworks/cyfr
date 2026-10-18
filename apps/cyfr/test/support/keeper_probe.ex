# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.KeeperProbe do
  @moduledoc """
  What a holder's lease keeper is doing when the holder ends its attempt.

  `watch/0` reports `{:attempt_ended, state}` to the calling process for
  each write that ends an attempt (the `execution_attempts` update that
  sets `ended_at`) made by a process with a lease keeper linked to it,
  read from inside that write: `:suspended`, `:renewing` or `:unknown`. A
  keeper still renewing there can renew again before its holder stops it,
  and that renewal finds the attempt ended and exits the holder
  `{:lease_lost, _}` after its work is done (`Opus.LeaseWatch`). A write
  by a process with no keeper races no renewal and is not reported.

  Each answer but `:unknown` is something seen: the keeper in its
  suspended wait, or blocked in its renewing wait or inside a renewal.
  A keeper that answered a suspend runs on into its suspended wait, so
  until it is seen in one of those the probe looks again. `:unknown` is a
  keeper seen in none of them within the bound: a failure to observe,
  never evidence of a renewal.

  Every process's writes are read, so it belongs in a module that is not
  `async`. The watch ends with the test.
  """

  @event [:arca, :repo, :query]
  # A keeper answers a suspend before it enters its suspended wait; a
  # loaded host can leave it unscheduled in between. A keeper seen settles
  # the answer at once, so the bound is spent only on one that is not.
  @settle_ms 2_000

  @doc "Report every attempt-ending write until the test ends."
  @spec watch() :: :ok
  def watch do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(id, @event, &__MODULE__.handle/4, self())
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def handle(_event, _measurements, %{source: "execution_attempts", query: query}, test) do
    if String.starts_with?(query, "UPDATE") and String.contains?(query, ~s("ended_at")) do
      case linked_keeper() do
        nil -> :ok
        keeper -> send(test, {:attempt_ended, state(keeper)})
      end
    end
  end

  def handle(_event, _measurements, _metadata, _test), do: :ok

  defp linked_keeper do
    {:links, links} = Process.info(self(), :links)
    Enum.find(links, &(is_pid(&1) and keeper?(&1)))
  end

  defp keeper?(pid) do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, frames} -> Enum.any?(frames, &(elem(&1, 0) == Opus.LeaseWatch))
      nil -> false
    end
  end

  defp state(keeper), do: state(keeper, System.monotonic_time(:millisecond) + @settle_ms)

  defp state(keeper, deadline) do
    case observe(keeper) do
      :settling ->
        if System.monotonic_time(:millisecond) >= deadline do
          :unknown
        else
          Process.sleep(1)
          state(keeper, deadline)
        end

      seen ->
        seen
    end
  end

  # One snapshot of the keeper. Waiting in `loop/1` is a keeper no suspend
  # reached; running there is one that may be on its way to `suspended/1`.
  defp observe(keeper) do
    case Process.info(keeper, [:current_function, :status, :current_stacktrace]) do
      [current_function: {Opus.LeaseWatch, :suspended, 1}, status: _, current_stacktrace: _] ->
        :suspended

      [current_function: {Opus.LeaseWatch, :loop, 1}, status: :waiting, current_stacktrace: _] ->
        :renewing

      [current_function: _, status: _, current_stacktrace: frames] ->
        if Enum.any?(frames, &match?({Opus.LeaseWatch, :renew, 1, _}, &1)),
          do: :renewing,
          else: :settling

      nil ->
        :unknown
    end
  end
end
