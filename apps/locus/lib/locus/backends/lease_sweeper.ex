# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends.LeaseSweeper do
  @moduledoc """
  The backends service's tick, once a second: it asks the owners
  (`Locus.Backends.Owners.sweep/1`) to retire every owner whose lease has
  passed and every ready backend no call has used within its owner's idle
  period (a backend with a call awaiting it, or waking, is not idle), and
  forgets the nonces whose window has passed
  (`Locus.Backends.Service.forget_expired_nonces/1`). It is a process of
  its own so the owners' process never waits on a timer, and it holds no
  state but its timer.
  """

  use GenServer

  alias Locus.Backends.{Owners, Service}

  @interval_ms 1_000

  @doc "Starts the tick. Options: `:owners` (`Locus.Backends.Owners`), `:interval_ms`, `:name`."
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "One tick, as the timer makes it."
  @spec sweep(GenServer.server()) :: :ok
  def sweep(owners \\ Owners) do
    Owners.sweep(owners)
    Service.forget_expired_nonces()
  end

  @impl GenServer
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @interval_ms)
    owners = Keyword.get(opts, :owners, Owners)
    {:ok, {owners, interval_ms, schedule(interval_ms)}}
  end

  @impl GenServer
  def handle_info(:tick, {owners, interval_ms, _timer}) do
    :ok = sweep(owners)
    {:noreply, {owners, interval_ms, schedule(interval_ms)}}
  end

  def handle_info(message, state) do
    Prima.LoggerContext.unexpected(__MODULE__, message)
    {:noreply, state}
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :tick, interval_ms)
end
