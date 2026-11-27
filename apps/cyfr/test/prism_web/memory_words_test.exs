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
    # Today's 10:38:20 and 10:41:00, in UTC.
    defp at, do: DateTime.new!(Date.utc_today(), ~T[10:38:20], "Etc/UTC")
    defp later, do: DateTime.new!(Date.utc_today(), ~T[10:41:00], "Etc/UTC")

    defp silent(runs, programs, builds) do
      MemoryWords.silent([
        %{endpoint: "wrk_local", heard_at: runs},
        %{endpoint: Opus.Programs.local(), heard_at: programs},
        %{endpoint: Prima.LocusPool.builds_endpoint(), heard_at: builds}
      ])
    end

    test "are one sentence, in the order builds, programs, runs" do
      # All in one minute of today: that time is every one's.
      assert silent(at(), at(), DateTime.add(at(), 35, :second)) ==
               "The services for builds, programs and runs have not answered since 10:38 UTC, " <>
                 "so what they run is not counted."

      # At different times: the time is the earliest, and is said to be.
      assert silent(later(), at(), later()) ==
               "The services for builds, programs and runs have not answered, the first of " <>
                 "them since 10:38 UTC, so what they run is not counted."
    end

    test "the same time on different days is not one time, and an earlier day's carries its date" do
      yesterday = DateTime.add(at(), -1, :day)
      day = Date.to_iso8601(DateTime.to_date(yesterday))

      assert silent(at(), yesterday, at()) ==
               "The services for builds, programs and runs have not answered, the first of " <>
                 "them since 10:38 UTC on #{day}, so what they run is not counted."

      # All yesterday in one minute: one time, with its date.
      assert silent(yesterday, yesterday, yesterday) ==
               "The services for builds, programs and runs have not answered since " <>
                 "10:38 UTC on #{day}, so what they run is not counted."

      assert MemoryWords.clock(at()) == "10:38 UTC"
      assert MemoryWords.clock(yesterday) == "10:38 UTC on #{day}"
    end

    test "one alone is said alone, the one service for runs without its id" do
      assert MemoryWords.silent([%{endpoint: "wrk_local", heard_at: at()}]) ==
               "The service for runs has not answered since 10:38 UTC, " <>
                 "so what it runs is not counted."

      assert MemoryWords.silent([]) == nil
    end

    test "a service for runs carries its id where CYFR knows several" do
      # One configured (`wrk_local`, config/test.exs) and another silent.
      assert MemoryWords.silent([%{endpoint: "wrk_gone", heard_at: at()}]) ==
               "The service for runs (wrk_gone) has not answered since 10:38 UTC, " <>
                 "so what it runs is not counted."

      assert MemoryWords.silent([
               %{endpoint: "wrk_b", heard_at: at()},
               %{endpoint: "wrk_a", heard_at: at()}
             ]) ==
               "The services for runs (wrk_a) and runs (wrk_b) have not answered since " <>
                 "10:38 UTC, so what they run is not counted."
    end
  end
end
