# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.RateLimiter do
  @moduledoc """
  Fixed-window request rate limiting in a dedicated ETS table.

  A shared runtime primitive with one instance owned by Sanctum's application
  tree. It is available to identity flows and Host callers without either
  starting another table owner. It stores no durable authority or budget.

  ## What this is, and what it is not

  **Advisory, and node-local by design.** Its buckets are ingress
  defence in depth: a per-address budget on sign-in, MCP, tincture and
  webhook traffic, a per-user budget on build validation, and the
  device flow's per-address and deployment-wide breakers. Each is one
  member's own count, so a cell of N members admits N times what one
  bucket names. That is stated rather than hidden, for two reasons: the
  ceiling that actually bounds a cell's ingress is the reverse proxy's,
  which sees every member's traffic where no member does; and nothing
  here is anyone's consent. A caller cannot buy authority by getting
  past a bucket, and a bucket that forgets everything on restart gives
  none away.

  One bucket is node-local for a stronger reason than the rest: a root
  execution's emit budget (`Crucible.Emit`) counts the events one
  guest run produces, and a root runs on exactly one member, so there is
  no second count in the cell for its own to disagree with. It is
  counted here because this is where it happens, and because it sits on
  the delta path — up to fifty events a second per root — where a
  round trip to a shared row would buy nothing the topology does not
  already give.

  **Nothing consented is enforced here.** An athanor's consented
  invocation rate is claimed in a row every member shares
  (`Arca.RateWindows`, through `Crucible.Rates`), where two
  members cannot admit it twice and a restart forgets nothing. A limit
  someone agreed to belongs there; a flood control on a transport, or on
  work one member is already doing, belongs here. A later reader wanting
  a cell-wide ceiling on one of these buckets is asking for the first of
  those, not for this table to be shared.

  The deployment-wide arms of the device flow (`{:device_init, :all}`,
  `{:device_poll, :all}`) are the closest thing here to a real ceiling —
  they guard the identity provider's opinion of one client id, which is
  a whole deployment's to spend — and they too are counted once per
  member, so a cell admits N times their maximum before the breaker
  trips everywhere.

  Kept separate from `Arca.Cache` on purpose: rate-limit keys are
  client-IP-derived, so their cardinality is **attacker-controlled**. Sharing a
  bounded table with sessions, OAuth CSRF state and tool metadata let a flood of
  distinct IPs evict that security state (and forced an O(n) eviction scan on the
  hot path). Here the counters live in their own table, swept on a timer, so a
  flood is contained to this table alone. The honest bound: the sweep
  reclaims counters a few minutes past their window, so the table holds up
  to a few minutes of DISTINCT key arrivals — small fixed rows, an
  attacker buys table entries, never evictions of security state.

  `check/3` is a read-then-count without a lock: N concurrent boundary
  requests can each pass the `count >= max` read before any increments, so
  the overshoot is off-by-concurrency, not off-by-one. Acceptable for an
  advisory limit (not a security boundary); the storage/authority caps
  make the same call explicitly at their own sites.

  The transport plugs (`EmissaryWeb.Plugs.*RateLimit`) all share `check/3`:

      case Prima.RateLimiter.check(key, max, window_ms) do
        :ok -> conn
        {:deny, retry_after_seconds} -> reject(conn, retry_after_seconds)
      end

  A counter is this member's, and its window starts again when this
  member does — losing a count is looser, never stricter, which is what
  an advisory bucket is allowed to be. An unavailable table fails CLOSED: this
  limiter fronts login brute-force, MCP, tincture and webhook ingress, and the
  table exists from boot — it is only missing while the supervision tree is
  dying, which is not the moment to wave throttled surfaces through. That
  includes `/health` (routed through the same throttle), so a limiter outage
  429s liveness probes and the orchestrator restarts the node — intended.
  """

  use GenServer

  require Logger

  @table :cyfr_rate_limiter
  @sweep_interval_ms :timer.minutes(1)
  # A window is at most a few minutes; a counter older than this is certainly
  # from a closed window and can be dropped.
  @stale_after_ms :timer.minutes(5)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record a hit against `key` and decide whether it is within `max` per
  `window_ms`. Returns `:ok` or `{:deny, retry_after_seconds}`.
  """
  @spec check(term(), pos_integer(), pos_integer()) :: :ok | {:deny, pos_integer()}
  def check(key, max, window_ms) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, count, window_start}] when now - window_start < window_ms ->
        if count >= max do
          {:deny, max(div(window_ms - (now - window_start), 1000), 1)}
        else
          :ets.update_counter(@table, key, {2, 1})
          :ok
        end

      _ ->
        # Absent or a closed window: start a fresh one.
        :ets.insert(@table, {key, 1, now})
        :ok
    end
  rescue
    ArgumentError ->
      Logger.error("[Prima.RateLimiter] table unavailable; denying request")
      {:deny, 1}
  end

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        write_concurrency: true,
        read_concurrency: true
      ])
    end

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - @stale_after_ms
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  @doc false
  def table_name, do: @table

  @doc "Clear all counters. Test seam."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
