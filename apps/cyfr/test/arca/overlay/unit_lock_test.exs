# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Overlay.UnitLockTest do
  @moduledoc """
  The lock has three release paths and needs all three.

  Two are obvious: `with_lock/3` releases when its function returns, and the
  monitor reclaims the turn when a holder dies. The third is the one that was
  missing — a caller whose `GenServer.call` timed out at the same moment
  `hand_over/3` gave it the turn. That caller is the holder and does not know
  it: `with_lock/3` already took its `{:error, :unit_locked}` branch, so it
  will never cast `{:release, …}`. `{:abandon, …}` used to filter only the
  waiter queue, so the unit stayed locked until the caller PROCESS died — and
  the callers are `Aqua.ConversationRunner`, Prism LiveViews and
  `Opus.CronScheduler`, which do not die.

  Runs against the supervised singleton (`start_link/1` pins the name), so
  every key here is unique to its test.
  """

  use ExUnit.Case, async: false

  alias Arca.Overlay.UnitLock

  defp unique_key, do: {:unit_lock_test, System.unique_integer([:positive])}

  defp entry(key), do: UnitLock |> :sys.get_state() |> Map.get(key)

  defp holder_of(key) do
    case entry(key) do
      {holder, _ref, _waiters} -> holder
      nil -> nil
    end
  end

  defp queued?(key) do
    case entry(key) do
      {_holder, _ref, waiters} -> not :queue.is_empty(waiters)
      nil -> false
    end
  end

  defp wait_until(fun, remaining \\ 2_000)
  defp wait_until(_fun, remaining) when remaining <= 0, do: flunk("condition never became true")

  defp wait_until(fun, remaining) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, remaining - 10)
    end
  end

  test "a timed-out waiter that is handed the turn releases it instead of stranding it" do
    key = unique_key()

    holder =
      spawn(fn ->
        GenServer.call(UnitLock, {:acquire, key})
        receive do: (:release -> GenServer.cast(UnitLock, {:release, key, self()}))
      end)

    wait_until(fn -> holder_of(key) == holder end)

    # The waiter gives up after 1ms but stays queued, then holds its abandon
    # until the test says go. That reproduces the race exactly: the cast is in
    # flight at the moment `hand_over/3` installs this process as the holder.
    waiter =
      spawn(fn ->
        catch_exit(GenServer.call(UnitLock, {:acquire, key}, 1))
        receive do: (:now -> GenServer.cast(UnitLock, {:abandon, key, self()}))
        # The bug is that the lock survives a LIVE abandoning caller, so this
        # process must outlive the assertion or the monitor would mask it.
        receive do: (:stop -> :ok)
      end)

    wait_until(fn -> queued?(key) end)
    send(holder, :release)

    # The hand-off gave the turn to a caller that had already stopped waiting.
    wait_until(fn -> holder_of(key) == waiter end)

    send(waiter, :now)

    wait_until(fn -> holder_of(key) == nil end)

    assert Process.alive?(waiter),
           "the abandoning caller must still be alive — otherwise the monitor, " <>
             "not the abandon handler, is what freed the lock"

    send(waiter, :stop)
  end

  test "abandoning while still queued drops the waiter and leaves the holder alone" do
    key = unique_key()

    holder =
      spawn(fn ->
        GenServer.call(UnitLock, {:acquire, key})
        receive do: (:release -> GenServer.cast(UnitLock, {:release, key, self()}))
      end)

    wait_until(fn -> holder_of(key) == holder end)

    waiter = spawn(fn -> catch_exit(GenServer.call(UnitLock, {:acquire, key}, 1)) end)
    wait_until(fn -> queued?(key) end)

    GenServer.cast(UnitLock, {:abandon, key, waiter})
    wait_until(fn -> not queued?(key) end)

    assert holder_of(key) == holder, "abandoning a waiter must not disturb the holder"

    send(holder, :release)
    wait_until(fn -> holder_of(key) == nil end)
  end
end
