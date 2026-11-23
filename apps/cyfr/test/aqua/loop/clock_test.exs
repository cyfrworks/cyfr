# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.ClockTest do
  @moduledoc """
  A turn's active time is read as one value: a reader racing the loop's
  pauses and resumes never counts a running interval twice, so the time it
  reads never passes the time that went by.
  """

  use ExUnit.Case, async: true

  alias Aqua.Loop.Clock

  test "a read racing pauses and resumes never reads more time than went by" do
    start = System.monotonic_time(:millisecond)
    clock = Clock.new(0)
    test = self()

    reader = spawn_link(fn -> send(test, {:read, reading(clock, start)}) end)

    # The loop's own writes: each running interval is banked as it ends.
    Enum.reduce(1..400, 0, fn _round, banked ->
      Clock.running(clock, banked)
      ran = System.monotonic_time(:millisecond)
      spin_until(ran + 3)
      banked = banked + (System.monotonic_time(:millisecond) - ran)
      Clock.paused(clock, banked)
      banked
    end)

    send(reader, :stop)
    assert_receive {:read, :within}, 5_000
  end

  test "a paused clock holds its time, and a running one adds what runs" do
    clock = Clock.new(1_000)
    assert Clock.read(clock) >= 1_000
    Clock.paused(clock, 1_500)
    assert Clock.read(clock) == 1_500
    Clock.running(clock, 1_500)
    assert Clock.read(clock) >= 1_500
  end

  # Reads until stopped, or until a read passes the time that went by.
  defp reading(clock, start) do
    receive do
      :stop -> :within
    after
      0 ->
        read = Clock.read(clock)
        went = System.monotonic_time(:millisecond) - start

        if read > went + 1, do: {:over, read, went}, else: reading(clock, start)
    end
  end

  # The loop's interval runs, busy, for the scheduler the reader shares.
  defp spin_until(ms) do
    if System.monotonic_time(:millisecond) < ms, do: spin_until(ms), else: :ok
  end
end
