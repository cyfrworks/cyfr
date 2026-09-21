# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RetentionScheduler do
  @moduledoc """
  Periodic retention cleanup, enabled when retention is configured, and
  run by one member of the cell at a time.

  When retention is disabled, this GenServer returns `:ignore` and never
  starts. When enabled, each tick asks for the cell's `retention` claim
  (`Arca.JobClaims`, key `"cell"`) and, holding it, runs one cycle: every
  kind in `Cyfr.Retention.kinds/0` inside every active athanor, each in
  its own context, plus the declared sweeps below. The tick repeats on a
  configurable interval (default 6 hours) to prevent unbounded storage
  growth. Every step runs behind one crash barrier: a fault in one is
  logged and the cycle moves on.

  ## Only a current claimant acts

  A tick does nothing unless this member holds its slot in the cell
  (`Arca.ControlPlane.held?/0` — a term read, no query) *and* wins the
  claim row. A member that finds a live peer holding it answers
  `{:busy, owner}` and does nothing; it does not take a live claim. The
  claim is leased for five minutes and renewed about once a minute, so a
  member that dies mid-cycle is succeeded within a lease and one tick.

  Losing the claim stops the cycle where it stands rather than letting it
  finish under a claim somebody else holds. The two ways to lose mean
  different things and are answered differently: `:taken` is a peer
  holding the row — nothing more is written; `:lapsed` is this member's
  own lease having run out with nobody yet taking it — the cursor is
  still recorded, because evidence a successor inherits is worth keeping
  whether or not the lease that produced it stood, and then the cycle
  stops.

  ## The cursor, and what survives a takeover

  A cycle is an ordered roster of steps, and the `retention` step is a
  walk over the active athanors in id order. `detail` on the claim row
  carries where the walk had reached:

      {"cycle": "2026-09-22T09:00:00.000000Z", "step": "retention",
       "athanor": "ath_01K…"}

    * `cycle` — the cell's clock when this cycle began.
    * `step` — the next step to run, or `null` once the cycle finished.
    * `athanor` — inside the `retention` step, the last athanor whose
      cleanup completed; `null` before the first.

  The cursor advances only when a unit of work has *completed*, so an
  interrupted step is redone and never skipped, and a completed one is
  not repeated. A successor that takes the row over reads `detail` —
  `Arca.JobClaims` leaves it exactly as it found it on a takeover — and
  resumes from it while the recorded cycle is younger than the tick
  interval. An older cycle is due again, so the successor starts a fresh
  one rather than finishing a stale walk.

  The cursor rides the same conditional statement as the renew
  (`Arca.JobClaims.renew/3` with `:detail`), never a second write, so a
  takeover racing it either loses or finds it whole.
  """

  use GenServer

  require Logger

  alias Arca.JobClaims
  alias Arca.Schemas.JobClaim

  @default_interval_ms :timer.hours(6)

  @kind "retention"
  @lease_ms :timer.minutes(5)
  @renew_ms :timer.minutes(1)

  # The declared roster of a cycle, in order: the id written to `detail`
  # and the label the log prints. `retention` is the per-athanor walk; the
  # rest are recurring reclaims that are not per-kind retention policy.
  @steps [
    {"flush", "record sink flush"},
    {"retention", "retention cleanup"},
    {"sessions", "expired session sweep"},
    {"webhooks", "webhook delivery sweep"},
    {"tmp", "stale tmp sweep"},
    {"blobs", "thread blob orphan sweep"}
  ]

  @typedoc """
  What one member did under one claim: the cycle it belongs to, whether
  it resumed a predecessor's, the steps it carried to completion, the
  athanors it swept and what it deleted in them, per kind.
  """
  @type summary :: %{
          cycle: DateTime.t(),
          resumed: boolean(),
          steps: [String.t()],
          athanors: [String.t()],
          deleted: %{String.t() => non_neg_integer()}
        }

  @typedoc "Why a cycle stopped part-way."
  @type stopped :: :taken | :lapsed | :not_held | :unavailable

  def start_link(opts \\ []) do
    if Application.get_env(:cyfr, :retention_scheduler_enabled, true) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end

  @impl true
  def init(_opts) do
    interval = interval()
    Logger.info("[RetentionScheduler] Starting with interval #{div(interval, 60_000)}m")
    {:ok, %{interval: interval}, {:continue, :first_run}}
  end

  @impl true
  def handle_continue(:first_run, state) do
    tick(state)
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:run_cleanup, state) do
    tick(state)
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  @doc """
  Run one retention cycle under the cell's `retention` claim.

  `opts`: `:key` (the claim key, `"cell"` by default), `:owner` (the
  member the claim is taken for, this boot by default), `:lease_ms`,
  `:renew_ms` and `:interval` (how old a recorded cycle may be and still
  be resumed).

  The four answers are different facts, and a caller must tell them
  apart: the cycle ran to its end, a live peer holds the claim and this
  member did nothing, the cycle stopped part-way and why, or the claim
  could not be asked for at all.
  """
  @spec cycle(keyword()) ::
          {:ok, summary()}
          | {:busy, String.t()}
          | {:stopped, stopped(), summary()}
          | {:error, :database_error}
  def cycle(opts \\ []) when is_list(opts) do
    key = Keyword.get(opts, :key, JobClaim.cell_key())
    owner = Keyword.get(opts, :owner, Cyfr.Boot.id())
    lease_ms = Keyword.get(opts, :lease_ms, @lease_ms)

    case JobClaims.claim(@kind, key, owner, lease_ms) do
      {:ok, claim} -> open(claim, opts, lease_ms)
      {:busy, %JobClaim{owner: peer}} -> {:busy, peer}
      {:error, :database_error} = unavailable -> unavailable
    end
  end

  # ---------------------------------------------------------------------------
  # The cycle
  # ---------------------------------------------------------------------------

  defp tick(state) do
    if Arca.ControlPlane.held?() do
      opts =
        state
        |> Map.get(:job, [])
        |> Keyword.put_new(:interval, Map.get(state, :interval, @default_interval_ms))

      report(cycle(opts))
    end
  end

  defp open(claim, opts, lease_ms) do
    case cell_now() do
      {:ok, now} ->
        cursor = resume(claim, now, Keyword.get(opts, :interval, interval()))

        walk(%{
          claim: claim,
          lease_ms: lease_ms,
          renew_ms: Keyword.get(opts, :renew_ms, @renew_ms),
          due: System.monotonic_time(:millisecond) + Keyword.get(opts, :renew_ms, @renew_ms),
          cursor: cursor,
          summary: %{
            cycle: cursor.cycle,
            resumed: cursor.resumed,
            steps: [],
            athanors: [],
            deleted: %{}
          }
        })

      :unavailable ->
        # The cell's clock decides which cycle the recorded cursor belongs
        # to. A cycle started without reading it would resume a walk it
        # cannot date, or restart one it should have finished.
        {:stopped, :unavailable,
         %{
           cycle: DateTime.utc_now(),
           resumed: false,
           steps: [],
           athanors: [],
           deleted: %{}
         }}
    end
  end

  # The cursor this member carries on from: the one `detail` records while
  # its cycle is younger than a tick interval, or a fresh cycle. A
  # takeover leaves `detail` as it found it, so what is read here is what
  # the predecessor had completed.
  defp resume(%JobClaim{detail: detail}, now, interval) do
    with %{"cycle" => cycle, "step" => step} = recorded when is_binary(step) <- decode(detail),
         {:ok, began, _offset} <- DateTime.from_iso8601(cycle),
         true <- step in step_ids(),
         true <- DateTime.diff(now, began, :millisecond) < interval do
      %{cycle: began, step: step, athanor: athanor_of(recorded), resumed: true}
    else
      _fresh -> %{cycle: now, step: first_step(), athanor: nil, resumed: false}
    end
  end

  defp walk(%{cursor: %{step: nil}} = state) do
    case mark(state, :force) do
      {:ok, held} ->
        _ = JobClaims.release(held)
        {:ok, state.summary}

      {:stopped, why} ->
        {:stopped, why, state.summary}
    end
  end

  defp walk(state) do
    cond do
      not Arca.ControlPlane.held?() ->
        # This member's slot in the cell lapsed under it. The rows are the
        # holder's to settle, so it gives the claim up rather than going
        # on: a successor takes it at once and resumes from the cursor.
        _ = JobClaims.release(state.claim)
        {:stopped, :not_held, state.summary}

      state.cursor.step == "retention" ->
        retention(state)

      true ->
        step(state)
    end
  end

  # One of the single-call steps. The cursor advances only once the step
  # has completed, so an interrupted one is redone rather than skipped.
  defp step(%{cursor: %{step: id}} = state) do
    run_step(label(id), step_fun(id))

    state
    |> put_cursor(%{state.cursor | step: next_step(id), athanor: nil})
    |> tally(:steps, id)
    |> advance(:force)
  end

  # The per-athanor walk. Athanors are taken in id order so the cursor —
  # the last one finished — names a position in a list every member
  # computes the same way, and a roster that changed between members only
  # adds or removes tenants around it.
  defp retention(%{cursor: %{athanor: from}} = state) do
    remaining =
      Sanctum.Tenancy.Athanors.list_active()
      |> Enum.map(& &1.id)
      |> Enum.sort()
      |> Enum.filter(&(is_nil(from) or &1 > from))

    sweep_athanors(state, remaining)
  end

  defp sweep_athanors(state, []) do
    state
    |> put_cursor(%{state.cursor | step: next_step("retention"), athanor: nil})
    |> tally(:steps, "retention")
    |> advance(:force)
  end

  defp sweep_athanors(state, [athanor_id | rest]) do
    if Arca.ControlPlane.held?() do
      deleted = run_step(label("retention"), fn -> run_retention(athanor_id) end)

      state
      |> put_cursor(%{state.cursor | athanor: athanor_id})
      |> tally(:athanors, athanor_id)
      |> count(deleted)
      |> renew_then(fn held -> sweep_athanors(held, rest) end)
    else
      _ = JobClaims.release(state.claim)
      {:stopped, :not_held, state.summary}
    end
  end

  defp advance(state, when_to_renew) do
    case mark(state, when_to_renew) do
      {:ok, held} -> walk(%{state | claim: held, due: renew_due(state, when_to_renew)})
      {:stopped, why} -> {:stopped, why, state.summary}
    end
  end

  defp renew_then(state, continue) do
    case mark(state, :when_due) do
      {:ok, held} -> continue.(%{state | claim: held, due: renew_due(state, :when_due)})
      {:stopped, why} -> {:stopped, why, state.summary}
    end
  end

  # Push the lease out and write the cursor in the SAME conditional
  # statement, so a takeover racing it either loses or finds it whole.
  # Renewing is an act of authority and lands only while the lease still
  # stands; recording is an act of evidence, so a lapse still writes the
  # cursor the successor inherits, and only then stops.
  defp mark(state, when_to_renew) do
    if when_to_renew == :force or System.monotonic_time(:millisecond) >= state.due do
      case JobClaims.renew(state.claim, state.lease_ms, detail: encode(state.cursor)) do
        {:ok, held} ->
          {:ok, held}

        :lapsed ->
          _ = JobClaims.record(state.claim, encode(state.cursor))
          {:stopped, :lapsed}

        :taken ->
          {:stopped, :taken}

        {:error, :database_error} ->
          {:stopped, :unavailable}
      end
    else
      {:ok, state.claim}
    end
  end

  defp renew_due(state, :force), do: System.monotonic_time(:millisecond) + state.renew_ms

  defp renew_due(state, :when_due) do
    now = System.monotonic_time(:millisecond)
    if now >= state.due, do: now + state.renew_ms, else: state.due
  end

  defp put_cursor(state, cursor), do: %{state | cursor: cursor}

  defp tally(state, field, value),
    do: %{state | summary: Map.update!(state.summary, field, &(&1 ++ [value]))}

  # What this member deleted, per kind, across the athanors it swept. A
  # crashed step's tally is nothing rather than a zero — the barrier
  # answers `nil` and the totals say what was actually reclaimed.
  defp count(state, %{} = deleted) do
    summed = Map.merge(state.summary.deleted, deleted, fn _kind, a, b -> a + b end)
    %{state | summary: %{state.summary | deleted: summed}}
  end

  defp count(state, _crashed), do: state

  # ---------------------------------------------------------------------------
  # The steps
  # ---------------------------------------------------------------------------

  defp step_fun("flush") do
    # Settle the write-behind first so a sweep sees every completion that
    # was queued before it — a row about to be pruned should not have a
    # pending update racing the delete.
    fn -> Arca.RecordSink.flush() end
  end

  defp step_fun("sessions"), do: &sweep_expired_sessions/0
  defp step_fun("webhooks"), do: &sweep_webhook_deliveries/0
  defp step_fun("tmp"), do: &sweep_stale_tmp_files/0
  defp step_fun("blobs"), do: &sweep_thread_blob_orphans/0

  # Sweep expired sessions; authentication reads independently enforce expiry.
  defp sweep_expired_sessions do
    case Sanctum.Session.cleanup() do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info("[RetentionScheduler] Removed #{count} expired session(s)")

      {:error, reason} ->
        Logger.warning("[RetentionScheduler] Expired-session sweep failed: #{inspect(reason)}")
    end
  end

  # One crash barrier for every step: retention must never take the
  # server down, and one step's fault must not starve the rest.
  #
  # Deliberately broader than `Arca.Repo.Errors.db_errors()`: the DB layer
  # under every step already answers outages as tuples, so what raises here
  # is a storage-adapter or shape fault — and letting one escape would
  # crash this GenServer, whose restart re-runs the whole cycle from
  # `handle_continue(:first_run, ...)`, turning one deterministic fault
  # into a restart loop that can exhaust the supervisor: exactly the
  # "retention takes the server down" this barrier exists to prevent. The
  # full stacktrace is logged so a swallowed bug is still loud.
  defp run_step(label, fun) do
    fun.()
  rescue
    e ->
      Logger.error(
        "[RetentionScheduler] #{label} crashed: " <> Exception.format(:error, e, __STACKTRACE__)
      )

      nil
  end

  # One athanor's whole policy. Answers what it deleted, per kind, which
  # the cycle sums and reports once rather than a line per tenant.
  defp run_retention(athanor_id) do
    {:ok, %{deleted: deleted, errors: errors}} = Cyfr.Retention.cleanup_athanor(athanor_id)

    # The athanor rides as metadata, not as text in the sentence: it is on
    # the configured log roster, so an aggregator can filter a whole tenant's
    # retention failures out of a shared server without parsing messages.
    for {failed_in, kind, reason} <- errors do
      Logger.warning("[RetentionScheduler] #{kind} cleanup failed: #{inspect(reason)}",
        athanor_id: failed_in
      )
    end

    deleted
  end

  # Thread blob dirs no row backs (a blob delete that failed after
  # its rows were reclaimed) — swept so the bytes stop counting against
  # the athanor's storage cap forever.
  defp sweep_thread_blob_orphans do
    case Cyfr.Retention.sweep_thread_blob_orphans() do
      {:ok, %{dirs_deleted: 0, errors: []}} ->
        :ok

      {:ok, %{dirs_deleted: deleted, tenants: tenants, errors: errors}} ->
        if deleted > 0 do
          Logger.info(
            "[RetentionScheduler] Reclaimed #{deleted} orphaned thread blob dirs " <>
              "across #{tenants} tenants"
          )
        end

        for {athanor_id, reason} <- errors do
          Logger.warning("[RetentionScheduler] Blob orphan sweep failed: #{inspect(reason)}",
            athanor_id: athanor_id
          )
        end

        :ok
    end
  end

  # Orphaned atomic-write temp files are an adapter artifact; the facade
  # asks whichever adapter is configured, and one with nothing to reclaim
  # answers zero.
  defp sweep_stale_tmp_files do
    case Arca.sweep_stale_tmp() do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info("[RetentionScheduler] Removed #{count} stale temp files")

      {:error, reason} ->
        Logger.warning("[RetentionScheduler] Temp sweep failed: #{inspect(reason)}")
    end
  end

  # Webhook idempotency table sweep. Default TTL 24h — webhook senders that
  # retry beyond this window cannot rely on idempotency, but in practice
  # senders give up well before that.
  defp sweep_webhook_deliveries do
    ttl = Application.get_env(:cyfr, :webhook_idempotency_ttl_seconds, 86_400)
    cutoff = DateTime.utc_now() |> DateTime.add(-ttl, :second)

    case Arca.WebhookDeliveryStorage.sweep(cutoff) do
      {:ok, count} when count > 0 ->
        Logger.info("[RetentionScheduler] Cleaned #{count} webhook delivery records")

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[RetentionScheduler] Webhook delivery sweep failed: #{inspect(reason)}")
    end
  end

  # ---------------------------------------------------------------------------
  # The roster, the cursor's bytes and the clock
  # ---------------------------------------------------------------------------

  defp step_ids, do: Enum.map(@steps, &elem(&1, 0))

  defp first_step, do: @steps |> hd() |> elem(0)

  defp next_step(id) do
    case Enum.drop_while(step_ids(), &(&1 != id)) do
      [^id, next | _rest] -> next
      _last -> nil
    end
  end

  defp label(id), do: Enum.find_value(@steps, id, fn {step, label} -> step == id && label end)

  defp encode(%{cycle: cycle, step: step, athanor: athanor}) do
    Jason.encode!(%{
      "cycle" => DateTime.to_iso8601(cycle),
      "step" => step,
      "athanor" => athanor
    })
  end

  defp decode(nil), do: nil

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> map
      _unreadable -> nil
    end
  end

  defp athanor_of(%{"athanor" => id}) when is_binary(id) and id != "", do: id
  defp athanor_of(_recorded), do: nil

  # The cell's clock, which dates the cycle every member reads. A store
  # that cannot answer it stops the tick rather than dating a walk on a
  # clock it could not read.
  defp cell_now do
    {:ok, Arca.ServerMetaStorage.now!()}
  rescue
    _exception -> :unavailable
  catch
    :exit, _reason -> :unavailable
  end

  defp interval,
    do: Application.get_env(:cyfr, :retention_scheduler_interval, @default_interval_ms)

  defp schedule(interval), do: Process.send_after(self(), :run_cleanup, interval)

  defp report({:ok, summary}) do
    reclaimed(summary)

    if summary.resumed do
      Logger.info(
        "[RetentionScheduler] Resumed a cycle a peer left: #{length(summary.steps)} step(s), " <>
          "#{length(summary.athanors)} athanor(s)"
      )
    end

    :ok
  end

  defp report({:busy, owner}) do
    Logger.debug("[RetentionScheduler] The cycle is #{owner}'s this tick")
    :ok
  end

  defp report({:stopped, why, summary}) do
    reclaimed(summary)

    Logger.warning(
      "[RetentionScheduler] The cycle stopped (#{why}) after #{length(summary.steps)} step(s) " <>
        "and #{length(summary.athanors)} athanor(s); the cursor is on the claim"
    )

    :ok
  end

  defp report({:error, :database_error}) do
    Logger.warning("[RetentionScheduler] The retention claim could not be read this tick")
    :ok
  end

  defp reclaimed(%{deleted: deleted, athanors: athanors}) do
    cleaned = for {kind, count} <- Enum.sort(deleted), count > 0, do: "#{count} #{kind}"

    if cleaned != [] do
      Logger.info(
        "[RetentionScheduler] Cleaned #{Enum.join(cleaned, ", ")} across " <>
          "#{length(athanors)} tenants"
      )
    end

    :ok
  end
end
