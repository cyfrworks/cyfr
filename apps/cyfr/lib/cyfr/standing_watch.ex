# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.StandingWatch do
  @moduledoc """
  Drops this member's cached authorization decisions when any member of
  the cell says one is no longer good.

  `Sanctum.Caller` memoizes an established Context for a short TTL, and
  that memo is a cached *authorization* decision carrying the athanor it
  was established in — the status gates the next establish would run are
  exactly what a hit skips. Every session mutation that narrows what a
  live session may reach drops it: logout, a repointed session, a
  revocation, a membership removal, an archived athanor.

  The drop is node-local, because the table is. The identity domain is
  below the host and announces rather than broadcasting
  (`Sanctum.Telemetry.caller_invalidated/1`), the host's bridge puts that
  on `Cyfr.Bus.caller_invalidated_global/0`, and this watch — one per
  member — drops what its own member holds.

  ## The bound when a delivery is lost

  PubSub delivery is best effort: a partition, a restarting subscriber or
  a dropped message means a peer never hears. The memo's TTL
  (`config :sanctum, :caller_memo_ttl_ms`, 2 s) is therefore the bound,
  not the mechanism — a revoked authority cannot survive longer than that
  anywhere in the cell, whether or not the announcement arrived, and the
  broadcast is what makes the usual case immediate instead.

  It holds no state and asks no store, so it starts on every member with
  no gate: a member that could not drop a memo it holds is the one
  failure this exists to prevent.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Emissary.PubSub, Cyfr.Bus.caller_invalidated_global())
    {:ok, %{}}
  end

  @impl true
  def handle_info({:caller_invalidated, hash}, state) when is_binary(hash) do
    Sanctum.Caller.drop_memo(hash)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end
end
