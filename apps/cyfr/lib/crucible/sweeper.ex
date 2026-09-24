# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.Sweeper do
  @moduledoc """
  Periodic sweep that lapses running executions whose lease lapsed, and
  cancels the open work of an estate that was archived.

  Runs every 60 seconds. A running row's attempt carries a lease
  (`execution_attempts.lease_until`) that its runner renews while the work
  runs, or that a turn root's keeper renews; a lapsed lease means nothing
  renewed it — the runner or its worker service is gone, a partition
  outlasted the lease, or a boot restarted. Each such execution is lapsed
  (`Crucible.Lapse`), wherever it was dispatched, and the attempt
  process still open for it is stopped (`Crucible.Attempt.stop_unclosed/2`),
  so its waiter answers the lapsed row.

  A tick sweeps only while this member holds its slot in the cell
  (`Arca.ControlPlane.held?/0`). The process starts only when
  `config :cyfr, :execution_sweeper_enabled` is true (the default).

  The sweep needs no claim of its own. Its authority is the attempt row:
  `Arca.ExecutionAttempts.lapse/2` matches the exact `lease_until` the
  scan observed, so two members sweeping one attempt produce one lapse
  and one no-op. What it does need is the cell's clock
  (`Arca.ServerMetaStorage.now!/0`) for "the lease has run out", because
  two members could disagree about that and both would lapse: a member
  whose own clock runs fast would lapse attempts a peer is still
  renewing.

  ## Retired grants

  An archive retires the grant of every execution admitted in the estate
  (`Sanctum.ExecutionStanding`), and `Crucible.ArchiveWatch`
  cancels what is running when it hears of it. The announcement is only
  an accelerator: each sweep also pages through every open attempt whose
  stored grant no longer stands (`Sanctum.ExecutionStanding.retired_attempts/3`,
  a page at a time by attempt id, `bounds/0`) and asks for its normal
  cancellation — a turn's root ends the turn (`Arca.TurnStorage.finish/4`,
  which closes its attempt, its root row and its reservation together),
  any other run is cancelled as a caller's cancel is
  (`Crucible.Dispatch.cancel/3`). Each write is a retirement under
  the attempt's stored stamp (`Cyfr.Boundaries.system_responsibilities/0`):
  it never needs the grant to stand, never reports success, and matches
  only the attempt that carries the stamp. The cursor advances only past a
  page the sweep has acted on, a member that no longer holds its slot
  stops at once, and every sweep starts a fresh scan, so work that a
  failure left, or that changed while a scan ran, is found by the next.
  Work whose runner cannot be reached stays retired — it can renew and do
  nothing — until its lease lapses here.
  """

  use GenServer
  require Logger

  alias Crucible.{Attempt, Dispatch, Lapse}

  @sweep_interval_ms 60_000

  # One page of the retired scan.
  @retired_page 50

  @retired_message "the execution's athanor was archived"

  def start_link(opts \\ []) do
    # Timer-driven DB queries from a permanent process poison the test
    # sandbox (the lent connection outlives its owning test) — same gate
    # as CronScheduler/RetentionScheduler; test config turns it off and
    # the sweep logic is exercised directly.
    if Application.get_env(:cyfr, :execution_sweeper_enabled, true) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    if Arca.ControlPlane.held?(), do: sweep()
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  @doc "The configured bounds of the sweep: its interval, and one page of the retired scan."
  @spec bounds() :: %{interval_ms: pos_integer(), retired_page: pos_integer()}
  def bounds, do: %{interval_ms: @sweep_interval_ms, retired_page: @retired_page}

  @doc false
  def sweep do
    lapse_stale()
    retire_retired(nil)
  end

  defp lapse_stale do
    stale =
      try do
        # Database time, not this member's: see the module doc. `now!/0`
        # raises when the store cannot answer, which the rescue below
        # turns into an empty sweep — a lease decision taken on a clock
        # that could not be read is the one thing that must not happen.
        Arca.Execution.list_stale_running(Arca.ServerMetaStorage.now!())
      rescue
        e ->
          Logger.error(
            "[Crucible.Sweeper] Failed to query stale executions: #{Exception.message(e)}"
          )

          []
      end

    for record <- stale do
      if Lapse.lapse(record),
        do:
          Attempt.stop_unclosed(record.attempt, %{
            service_id: record.service_id,
            boot_id: record.boot_id,
            runner: nil
          })
    end

    :ok
  end

  # One page after another from `cursor`, each acted on before the cursor
  # moves past it; a short page ends the scan. A store that cannot answer
  # ends it too, and the next sweep scans afresh.
  defp retire_retired(cursor) do
    case Sanctum.ExecutionStanding.retired_attempts(Prima.Actor.system(), cursor, @retired_page) do
      {:ok, []} ->
        :ok

      {:ok, page} ->
        if Enum.all?(page, &retire/1) and length(page) == @retired_page do
          {_execution_id, last, _athanor_id, _generation} = List.last(page)
          retire_retired(last)
        else
          :ok
        end

      {:error, reason} ->
        Logger.error(
          "[Crucible.Sweeper] retired attempts could not be listed: #{inspect(reason)}"
        )

        :ok
    end
  end

  # The normal cancellation of one retired attempt, answering whether the
  # scan may go on: false once this member no longer holds its slot.
  defp retire({execution_id, _attempt, athanor_id, generation}) do
    if Arca.ControlPlane.held?() do
      {:ok, grant} = Prima.ExecutionGrant.new(athanor_id, generation)
      cancel(execution_id, athanor_id, grant)
      true
    else
      false
    end
  rescue
    exception ->
      Logger.error(
        "[Crucible.Sweeper] retired execution #{execution_id} was not cancelled: " <>
          Exception.message(exception)
      )

      true
  end

  defp cancel(execution_id, athanor_id, grant) do
    actor = Prima.Actor.in_athanor(athanor_id)

    case Arca.Execution.get_tenant(actor, execution_id) do
      %{kind: "turn", turn_id: turn_id} when is_binary(turn_id) ->
        end_turn(actor, execution_id, turn_id, grant)

      %{status: "running"} ->
        ctx = Sanctum.internal_context(athanor_id: athanor_id, scope: :athanor)
        _ = Dispatch.cancel(ctx, execution_id)
        :ok

      _other ->
        :ok
    end
  end

  # A turn's root ends with its turn, in the turn's one terminal
  # transaction; whatever still holds the root on this member is stopped
  # once the rows have ended.
  defp end_turn(actor, execution_id, turn_id, grant) do
    with {:ok, turn} <- Arca.TurnStorage.get(actor, turn_id),
         {:ok, ended} <-
           Arca.TurnStorage.finish(actor, turn_id, "cancelled", %{
             fence: turn.fence,
             error: @retired_message,
             grant: grant,
             verify: &Sanctum.ExecutionStanding.stamp_only/1
           }) do
      Logger.info("[Crucible.Sweeper] retired turn #{ended.id} ended cancelled")
      Dispatch.stop(execution_id, actor.athanor_id)
    else
      {:error, reason} ->
        Logger.warning(
          "[Crucible.Sweeper] retired turn #{turn_id} was not ended: #{inspect(reason)}"
        )
    end

    :ok
  end
end
