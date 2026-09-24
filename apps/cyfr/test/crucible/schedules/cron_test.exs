# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.Schedules.CronTest do
  use ExUnit.Case, async: true

  alias Crucible.Schedules.Cron

  describe "parse/1" do
    test "parses every-minute expression" do
      assert {:ok, cron} = Cron.parse("* * * * *")
      assert cron.minute == Enum.to_list(0..59)
      assert cron.hour == Enum.to_list(0..23)
      assert cron.dom == Enum.to_list(1..31)
      assert cron.month == Enum.to_list(1..12)
      assert cron.dow == Enum.to_list(0..6)
    end

    test "parses step expression" do
      assert {:ok, cron} = Cron.parse("*/15 * * * *")
      assert cron.minute == [0, 15, 30, 45]
    end

    test "parses specific values" do
      assert {:ok, cron} = Cron.parse("0 9 * * *")
      assert cron.minute == [0]
      assert cron.hour == [9]
    end

    test "parses ranges" do
      assert {:ok, cron} = Cron.parse("0 9-17 * * *")
      assert cron.hour == Enum.to_list(9..17)
    end

    test "parses lists" do
      assert {:ok, cron} = Cron.parse("0,30 * * * *")
      assert cron.minute == [0, 30]
    end

    test "parses range with step" do
      assert {:ok, cron} = Cron.parse("0-30/10 * * * *")
      assert cron.minute == [0, 10, 20, 30]
    end

    test "parses complex expression" do
      assert {:ok, cron} = Cron.parse("0,30 9-17 1,15 * 1-5")
      assert cron.minute == [0, 30]
      assert cron.hour == Enum.to_list(9..17)
      assert cron.dom == [1, 15]
      assert cron.dow == [1, 2, 3, 4, 5]
    end

    test "rejects invalid field count" do
      assert {:error, _} = Cron.parse("* * *")
      assert {:error, _} = Cron.parse("* * * * * *")
    end

    test "rejects out-of-range values" do
      assert {:error, _} = Cron.parse("60 * * * *")
      assert {:error, _} = Cron.parse("* 25 * * *")
    end

    test "rejects invalid step" do
      assert {:error, _} = Cron.parse("*/0 * * * *")
    end
  end

  describe "valid?/1" do
    test "returns true for valid expressions" do
      assert Cron.valid?("* * * * *")
      assert Cron.valid?("*/5 * * * *")
      assert Cron.valid?("0 9 * * 1-5")
    end

    test "returns false for invalid expressions" do
      refute Cron.valid?("bad")
      refute Cron.valid?("60 * * * *")
    end
  end

  describe "next_run/2" do
    test "finds next minute for every-minute cron" do
      {:ok, cron} = Cron.parse("* * * * *")
      ref = ~U[2025-01-01 12:00:00Z]
      assert {:ok, next} = Cron.next_run(cron, ref)
      assert next == ~U[2025-01-01 12:01:00.000000Z]
    end

    test "finds next occurrence for specific time" do
      {:ok, cron} = Cron.parse("30 9 * * *")
      ref = ~U[2025-01-01 08:00:00Z]
      assert {:ok, next} = Cron.next_run(cron, ref)
      assert next.hour == 9
      assert next.minute == 30
      assert next.day == 1
    end

    test "rolls to next day when past time" do
      {:ok, cron} = Cron.parse("0 9 * * *")
      ref = ~U[2025-01-01 10:00:00Z]
      assert {:ok, next} = Cron.next_run(cron, ref)
      assert next.day == 2
      assert next.hour == 9
      assert next.minute == 0
    end

    test "respects month boundaries" do
      {:ok, cron} = Cron.parse("0 0 1 * *")
      ref = ~U[2025-01-15 00:00:00Z]
      assert {:ok, next} = Cron.next_run(cron, ref)
      assert next.month == 2
      assert next.day == 1
    end

    test "handles step expressions" do
      {:ok, cron} = Cron.parse("*/15 * * * *")
      ref = ~U[2025-01-01 12:03:00Z]
      assert {:ok, next} = Cron.next_run(cron, ref)
      assert next.minute == 15
    end

    test "handles day of week" do
      {:ok, cron} = Cron.parse("0 9 * * 1")
      # 2025-01-01 is a Wednesday (dow=3)
      ref = ~U[2025-01-01 00:00:00Z]
      assert {:ok, next} = Cron.next_run(cron, ref)
      # Next Monday is Jan 6
      assert next.day == 6
      assert Date.day_of_week(next) |> rem(7) == 1
    end

    test "dow 7 is the Sunday alias" do
      {:ok, cron} = Cron.parse("0 9 * * 7")
      assert cron.dow == [0]

      # 2025-01-01 is a Wednesday; the next Sunday is Jan 5.
      assert {:ok, next} = Cron.next_run(cron, ~U[2025-01-01 00:00:00Z])
      assert next.day == 5
      assert Date.day_of_week(next) == 7
    end

    test "restricted dom AND dow fire on either (POSIX)" do
      # "0 0 13 * 5" is "the 13th OR any Friday", not Friday-the-13th.
      {:ok, cron} = Cron.parse("0 0 13 * 5")

      # 2025-01-01 is a Wednesday: the first match is Friday Jan 3,
      # before the 13th.
      assert {:ok, next} = Cron.next_run(cron, ~U[2025-01-01 00:00:00Z])
      assert next.month == 1
      assert next.day == 3

      # And from Saturday the 11th, the 13th (a Monday) beats the next
      # Friday (the 17th).
      assert {:ok, next} = Cron.next_run(cron, ~U[2025-01-11 00:00:00Z])
      assert next.day == 13
    end

    test "one restricted day field keeps plain conjunction" do
      # Only dow restricted: every Friday, any dom.
      {:ok, cron} = Cron.parse("0 0 * * 5")
      assert {:ok, next} = Cron.next_run(cron, ~U[2025-01-01 00:00:00Z])
      assert next.day == 3

      # Only dom restricted: the 13th, any weekday.
      {:ok, cron} = Cron.parse("0 0 13 * *")
      assert {:ok, next} = Cron.next_run(cron, ~U[2025-01-01 00:00:00Z])
      assert next.day == 13
    end

    test "a leap-day schedule finds the next Feb 29 after firing" do
      # Consecutive leap-day occurrences can be 1461 days apart.
      {:ok, cron} = Cron.parse("0 0 29 2 *")

      assert {:ok, next} = Cron.next_run(cron, ~U[2028-03-01 00:00:00Z])
      assert next.year == 2032
      assert next.month == 2
      assert next.day == 29
    end
  end

  describe "min_interval_seconds/1" do
    test "every minute = 60 seconds" do
      assert {:ok, 60} = Cron.min_interval_seconds("* * * * *")
    end

    test "every 5 minutes = 300 seconds" do
      assert {:ok, 300} = Cron.min_interval_seconds("*/5 * * * *")
    end

    test "hourly = 3600 seconds" do
      assert {:ok, 3600} = Cron.min_interval_seconds("0 * * * *")
    end
  end
end
