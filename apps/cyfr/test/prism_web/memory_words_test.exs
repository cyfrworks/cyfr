# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.MemoryWordsTest do
  use ExUnit.Case, async: true

  alias PrismWeb.MemoryWords

  test "a length of time is said in words" do
    assert Enum.map(
             [0, 999, 1_000, 49_999, 60_000, 179_000, 3_600_000, 3_660_000, 7_500_000],
             &MemoryWords.duration/1
           ) == [
             "under a second",
             "under a second",
             "1 second",
             "49 seconds",
             "1 minute",
             "2 minutes",
             "1 hour",
             "1 hour 1 minute",
             "2 hours 5 minutes"
           ]
  end

  test "a day's use is its average, then its most at once and the time measured in all" do
    day = %{mib_ms: 32 * 3_600_000, measured_ms: 3_660_000, peak_bytes: 246 * 1_048_576}

    # The second line breaks only between its two halves.
    assert MemoryWords.used(day) == [
             "31.5 MB on average",
             "at\u00a0most\u00a0246.0\u00a0MB, for\u00a01\u00a0hour\u00a01\u00a0minute\u00a0in\u00a0all"
           ]

    assert MemoryWords.used(%{mib_ms: 0, measured_ms: 500, peak_bytes: 100 * 1_048_576}) == [
             "0 B on average",
             "at\u00a0most\u00a0100.0\u00a0MB, for\u00a0under\u00a0a\u00a0second\u00a0in\u00a0all"
           ]
  end

  test "with no time measured a day's use is one line: its peak alone, or nothing measured" do
    assert MemoryWords.used(%{mib_ms: 0, measured_ms: 0, peak_bytes: 40 * 1_048_576}) ==
             ["at\u00a0most\u00a040.0\u00a0MB"]

    assert MemoryWords.used(%{mib_ms: 0, measured_ms: 0, peak_bytes: 0}) == ["nothing measured"]
  end

  describe "the services that have not answered" do
    @at ~U[2026-11-27 10:38:20Z]
    @later ~U[2026-11-27 10:41:00Z]

    test "are one sentence, in the order builds, programs, runs, since the earliest" do
      silent = [
        %{endpoint: "wrk_local", heard_at: @later},
        %{endpoint: Opus.Programs.local(), heard_at: @at},
        %{endpoint: Prima.LocusPool.builds_endpoint(), heard_at: @later}
      ]

      assert MemoryWords.silent(silent) ==
               "The services for builds, programs and runs have not answered since 10:38 UTC, " <>
                 "so what they run is not counted."
    end

    test "one alone is said alone, the one service for runs without its id" do
      assert MemoryWords.silent([%{endpoint: "wrk_local", heard_at: @at}]) ==
               "The service for runs has not answered since 10:38 UTC, " <>
                 "so what it runs is not counted."

      assert MemoryWords.silent([]) == nil
    end

    test "a service for runs carries its id where CYFR knows several" do
      # One configured (`wrk_local`, config/test.exs) and another silent.
      assert MemoryWords.silent([%{endpoint: "wrk_gone", heard_at: @at}]) ==
               "The service for runs (wrk_gone) has not answered since 10:38 UTC, " <>
                 "so what it runs is not counted."

      assert MemoryWords.silent([
               %{endpoint: "wrk_b", heard_at: @at},
               %{endpoint: "wrk_a", heard_at: @at}
             ]) ==
               "The services for runs (wrk_a) and runs (wrk_b) have not answered since " <>
                 "10:38 UTC, so what they run is not counted."
    end
  end

  test "a count no newer than a terminal's close says so, and a newer one is fresh again" do
    machine = %{heard_at: ~U[2026-11-27 10:38:20Z]}

    assert MemoryWords.counted(machine) == "Counted a few seconds ago."

    assert MemoryWords.counted(machine, ~U[2026-11-27 10:38:21Z]) ==
             "A terminal closed since this was counted."

    assert MemoryWords.counted(machine, ~U[2026-11-27 10:38:19Z]) == "Counted a few seconds ago."
  end
end
