# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.Clock do
  @moduledoc """
  A turn's active time, set by the loop that holds the turn as it claims,
  pauses and resumes its root, and read by the turn's harness
  (`work.active_ms`).

  The time is one value in one slot, so a reader never sees a pause half
  made: while the turn runs, the instant its banked time would have begun
  (`2 * (now - banked) + 1`, odd); while it is paused, the banked time
  itself (`2 * banked`, even).
  """

  @opaque t :: :atomics.atomics_ref()

  @doc "A clock running from now, with `active_ms` already banked."
  @spec new(non_neg_integer()) :: t()
  def new(active_ms), do: running(:atomics.new(1, signed: true), active_ms)

  @doc "The turn runs from now, with `active_ms` banked."
  @spec running(t(), non_neg_integer()) :: t()
  def running(clock, active_ms) do
    :ok = :atomics.put(clock, 1, 2 * (now() - active_ms) + 1)
    clock
  end

  @doc "The turn is paused, with `active_ms` banked."
  @spec paused(t(), non_neg_integer()) :: t()
  def paused(clock, active_ms) do
    :ok = :atomics.put(clock, 1, 2 * active_ms)
    clock
  end

  @doc """
  The turn's active time now, from one read of the slot. `now` is the
  time source, the monotonic clock in milliseconds unless given.

  The time is taken before the slot is read: a pause made between the
  two can only make the read count less than the turn ran, never more.
  """
  @spec read(t(), (-> integer())) :: non_neg_integer()
  def read(clock, now \\ &now/0) do
    at = now.()
    value = :atomics.get(clock, 1)

    if Integer.mod(value, 2) == 1,
      do: at - div(value - 1, 2),
      else: div(value, 2)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
