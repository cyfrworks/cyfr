# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.KeeperProbe do
  @moduledoc """
  What a holder's lease keeper is doing when the holder ends its attempt.

  `watch/0` reports `{:attempt_ended, state}` to the calling process for
  each write that ends an attempt (the `execution_attempts` update that
  sets `ended_at`) made by a process with a lease keeper linked to it,
  read from inside that write: `:suspended` or `:renewing`. A keeper still
  renewing there can renew again before its holder stops it, and that
  renewal finds the attempt ended and exits the holder `{:lease_lost, _}`
  after its work is done (`Crucible.LeaseWatch`). A write by a process
  with no keeper races no renewal and is not reported.

  Every process's writes are read, so it belongs in a module that is not
  `async`. The watch ends with the test.
  """

  @event [:arca, :repo, :query]
  # A keeper answers a suspend before it enters its suspended wait.
  @settle_ms 500

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
      {:current_stacktrace, frames} -> Enum.any?(frames, &(elem(&1, 0) == Crucible.LeaseWatch))
      nil -> false
    end
  end

  defp state(keeper), do: state(keeper, System.monotonic_time(:millisecond) + @settle_ms)

  defp state(keeper, deadline) do
    cond do
      Process.info(keeper, :current_function) ==
          {:current_function, {Crucible.LeaseWatch, :suspended, 2}} ->
        :suspended

      System.monotonic_time(:millisecond) >= deadline ->
        :renewing

      true ->
        Process.sleep(1)
        state(keeper, deadline)
    end
  end
end
