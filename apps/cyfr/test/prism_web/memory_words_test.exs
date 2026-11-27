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

  test "a day's average is its use over the time measured, and a dash with nothing measured" do
    assert MemoryWords.average(%{mib_ms: 32 * 3_600_000, measured_ms: 600_000}) ==
             "192.0 MB on average"

    assert MemoryWords.average(%{mib_ms: 0, measured_ms: 45_000}) == "0 B on average"
    assert MemoryWords.average(%{mib_ms: 0, measured_ms: 0}) == "—"
  end

  test "a day's most at once and its time measured break only between the two" do
    day = %{peak_bytes: 246 * 1_048_576, measured_ms: 3_660_000}

    assert MemoryWords.at_most(day) ==
             "at\u00a0most\u00a0246.0\u00a0MB, for\u00a01\u00a0hour\u00a01\u00a0minute"
  end
end
