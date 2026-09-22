# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Cluster.Wait do
  @moduledoc """
  Bounded condition checks, and the measurements a case reports against
  the bounds `docs/plans/cell-ownership.md` states.

  There are no sleeps in this suite that stand in for an event. Where a
  case needs two members to act at one instant it makes the interleaving
  (`Cyfr.Cluster.Barrier`); where it waits for a member to notice
  something, it polls a condition until a deadline and reports **how
  long** that took, so a bound is measured rather than assumed. A sleep
  would pass whether the bound held or not.

  `measure!/3` is the shape every recovery case uses: it answers the
  milliseconds that passed before the condition first held, and the caller
  asserts that against the documented bound. A case that meets a bound
  with no margin should say so; `margin/2` is how it works out what to
  say.
  """

  @default_timeout_ms 60_000
  @poll_ms 50

  @doc """
  Wait until `condition` answers truthy, or raise at the deadline.

  `condition` is re-run every 50 ms. It is re-run rather than watched
  because what it asks about is usually a row: there is no message to
  subscribe to when a peer's lease runs out.
  """
  @spec until!((-> as_boolean(term())), String.t(), timeout()) :: term()
  def until!(condition, message, timeout_ms \\ @default_timeout_ms) do
    {_elapsed, value} = measure!(condition, message, timeout_ms)
    value
  end

  @doc """
  Wait as `until!/3` does, and answer `{elapsed_ms, value}` — the
  milliseconds from the call to the first check that held.

  The clock is `System.monotonic_time/1`: what is being measured is how
  long one observer waited, which is exactly what a monotonic clock is for
  (`cell-ownership.md` §3).
  """
  @spec measure!((-> as_boolean(term())), String.t(), timeout()) ::
          {non_neg_integer(), term()}
  def measure!(condition, message, timeout_ms \\ @default_timeout_ms) do
    started = System.monotonic_time(:millisecond)
    deadline = started + timeout_ms
    poll(condition, message, started, deadline)
  end

  defp poll(condition, message, started, deadline) do
    case run(condition) do
      value when value not in [nil, false] ->
        {System.monotonic_time(:millisecond) - started, value}

      _not_yet ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "waited #{System.monotonic_time(:millisecond) - started} ms: #{message}"
        else
          Process.sleep(@poll_ms)
          poll(condition, message, started, deadline)
        end
    end
  end

  # A condition that raises has not held yet — a peer that is mid-restart
  # refuses the call that asks it. A condition that is still raising at
  # the deadline raises through the timeout message instead.
  defp run(condition) do
    condition.()
  catch
    _kind, _reason -> false
  end

  @doc """
  Hold `condition` false for `ms`, so a case can say a member did *not*
  act rather than only that it had not acted yet. Answers `:ok`, or raises
  naming when the condition first held.
  """
  @spec never!((-> as_boolean(term())), String.t(), pos_integer()) :: :ok
  def never!(condition, message, ms),
    do: hold(condition, message, System.monotonic_time(:millisecond) + ms)

  defp hold(condition, message, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      :ok
    else
      case run(condition) do
        value when value not in [nil, false] ->
          raise message

        _still_false ->
          Process.sleep(@poll_ms)
          hold(condition, message, deadline)
      end
    end
  end

  @doc """
  What a measurement had to spare against its bound, as a percentage of
  the bound. A case reports it so "met with no margin" is a number rather
  than an impression.
  """
  @spec margin(non_neg_integer(), pos_integer()) :: float()
  def margin(measured, bound), do: Float.round((bound - measured) / bound * 100, 1)

  @doc """
  Print one measurement against its bound, so a run's output carries the
  evidence rather than only its verdict.
  """
  @spec report(String.t(), non_neg_integer(), pos_integer()) :: :ok
  def report(what, measured, bound) do
    IO.puts(
      "    #{what}: #{measured} ms against a bound of #{bound} ms " <>
        "(#{margin(measured, bound)}% to spare)"
    )
  end
end
