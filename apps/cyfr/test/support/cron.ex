# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.Cron do
  @moduledoc """
  Cron expressions no tick of which comes due while a case runs.

  A claim reads the cell's clock: once a case has fired the cursor it set,
  the cursor moves to the expression's next time, and the scheduler's
  standing pass or the case's own next claim fires that time as an
  ordinary occurrence the moment it is due. An expression on a fixed grid,
  hourly at `0 * * * *` or daily at a fixed hour, comes due whenever the
  case happens to run across one of its times, so a case that fires a
  schedule and then asserts on its exact occurrences, or on a claim being
  held, names an expression from here: its times are named from the clock
  when the case runs, each as far from now as the expression allows.
  """

  @doc """
  An hourly expression at the minute half an hour from now: its last time
  is about half an hour ago and its next about half an hour ahead.
  """
  @spec hourly_away() :: String.t()
  def hourly_away do
    minute = DateTime.add(DateTime.utc_now(), 1_800, :second).minute
    "#{minute} * * * *"
  end

  @doc """
  A daily expression at the time of day twelve hours from now, with that
  time of day at the microsecond precision a stored `scheduled_for` reads
  back with: its nearest time is about twelve hours away either side.
  """
  @spec daily_away() :: {String.t(), Time.t()}
  def daily_away do
    %DateTime{hour: hour, minute: minute} = DateTime.add(DateTime.utc_now(), 12 * 3_600, :second)
    {"#{minute} #{hour} * * *", Time.new!(hour, minute, 0, {0, 6})}
  end
end
