# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.CronParserTest do
  use ExUnit.Case, async: true

  alias Opus.CronParser

  describe "parse/1" do
    test "parses every-minute expression" do
      assert {:ok, cron} = CronParser.parse("* * * * *")
      assert cron.minute == Enum.to_list(0..59)
      assert cron.hour == Enum.to_list(0..23)
      assert cron.dom == Enum.to_list(1..31)
      assert cron.month == Enum.to_list(1..12)
      assert cron.dow == Enum.to_list(0..6)
    end

    test "parses step expression" do
      assert {:ok, cron} = CronParser.parse("*/15 * * * *")
      assert cron.minute == [0, 15, 30, 45]
    end

    test "parses specific values" do
      assert {:ok, cron} = CronParser.parse("0 9 * * *")
      assert cron.minute == [0]
      assert cron.hour == [9]
    end

    test "parses ranges" do
      assert {:ok, cron} = CronParser.parse("0 9-17 * * *")
      assert cron.hour == Enum.to_list(9..17)
    end

    test "parses lists" do
      assert {:ok, cron} = CronParser.parse("0,30 * * * *")
      assert cron.minute == [0, 30]
    end

    test "parses range with step" do
      assert {:ok, cron} = CronParser.parse("0-30/10 * * * *")
      assert cron.minute == [0, 10, 20, 30]
    end

    test "parses complex expression" do
      assert {:ok, cron} = CronParser.parse("0,30 9-17 1,15 * 1-5")
      assert cron.minute == [0, 30]
      assert cron.hour == Enum.to_list(9..17)
      assert cron.dom == [1, 15]
      assert cron.dow == [1, 2, 3, 4, 5]
    end

    test "rejects invalid field count" do
      assert {:error, _} = CronParser.parse("* * *")
      assert {:error, _} = CronParser.parse("* * * * * *")
    end

    test "rejects out-of-range values" do
      assert {:error, _} = CronParser.parse("60 * * * *")
      assert {:error, _} = CronParser.parse("* 25 * * *")
    end

    test "rejects invalid step" do
      assert {:error, _} = CronParser.parse("*/0 * * * *")
    end
  end

  describe "valid?/1" do
    test "returns true for valid expressions" do
      assert CronParser.valid?("* * * * *")
      assert CronParser.valid?("*/5 * * * *")
      assert CronParser.valid?("0 9 * * 1-5")
    end

    test "returns false for invalid expressions" do
      refute CronParser.valid?("bad")
      refute CronParser.valid?("60 * * * *")
    end
  end

  describe "next_run/2" do
    test "finds next minute for every-minute cron" do
      {:ok, cron} = CronParser.parse("* * * * *")
      ref = ~U[2025-01-01 12:00:00Z]
      assert {:ok, next} = CronParser.next_run(cron, ref)
      assert next == ~U[2025-01-01 12:01:00.000000Z]
    end

    test "finds next occurrence for specific time" do
      {:ok, cron} = CronParser.parse("30 9 * * *")
      ref = ~U[2025-01-01 08:00:00Z]
      assert {:ok, next} = CronParser.next_run(cron, ref)
      assert next.hour == 9
      assert next.minute == 30
      assert next.day == 1
    end

    test "rolls to next day when past time" do
      {:ok, cron} = CronParser.parse("0 9 * * *")
      ref = ~U[2025-01-01 10:00:00Z]
      assert {:ok, next} = CronParser.next_run(cron, ref)
      assert next.day == 2
      assert next.hour == 9
      assert next.minute == 0
    end

    test "respects month boundaries" do
      {:ok, cron} = CronParser.parse("0 0 1 * *")
      ref = ~U[2025-01-15 00:00:00Z]
      assert {:ok, next} = CronParser.next_run(cron, ref)
      assert next.month == 2
      assert next.day == 1
    end

    test "handles step expressions" do
      {:ok, cron} = CronParser.parse("*/15 * * * *")
      ref = ~U[2025-01-01 12:03:00Z]
      assert {:ok, next} = CronParser.next_run(cron, ref)
      assert next.minute == 15
    end

    test "handles day of week" do
      {:ok, cron} = CronParser.parse("0 9 * * 1")
      # 2025-01-01 is a Wednesday (dow=3)
      ref = ~U[2025-01-01 00:00:00Z]
      assert {:ok, next} = CronParser.next_run(cron, ref)
      # Next Monday is Jan 6
      assert next.day == 6
      assert Date.day_of_week(next) |> rem(7) == 1
    end
  end

  describe "min_interval_seconds/1" do
    test "every minute = 60 seconds" do
      assert {:ok, 60} = CronParser.min_interval_seconds("* * * * *")
    end

    test "every 5 minutes = 300 seconds" do
      assert {:ok, 300} = CronParser.min_interval_seconds("*/5 * * * *")
    end

    test "hourly = 3600 seconds" do
      assert {:ok, 3600} = CronParser.min_interval_seconds("0 * * * *")
    end
  end
end
