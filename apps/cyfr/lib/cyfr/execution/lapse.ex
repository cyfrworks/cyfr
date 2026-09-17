# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Lapse do
  @moduledoc """
  Ends a running execution whose attempt stopped without closing it.

  A lapse closes the attempt `lapsed` with outcome `uncertain`, fenced on
  the attempt and the lease that was seen, so a renewal that landed since
  matches nothing; fails the row with an `execution.lapsed` event, fires
  the failure telemetry, publishes the event, and fails the children a
  formula or a turn root leaves running (`Cyfr.Execution.Cascade`).

  Three things find such an attempt: the sweeper, by its lapsed lease
  (`Cyfr.Execution.Sweeper`); a worker service's report that a runner
  exited, by the attempts it was started with
  (`Cyfr.Execution.Host.runner_exited/2`); and an attempt whose waiter
  exited, by its own id (`Cyfr.Execution.Attempt`).

  A boot that does not hold the control plane (`Cyfr.ControlPlane.owner?/0`)
  lapses nothing: the rows are the holder's to settle.
  """

  require Logger

  alias Cyfr.Execution.{Cascade, Events, Telemetry}

  @message "Execution terminated: runner stopped without cleanup"

  @doc """
  Lapse the execution of `record` — the row's map with its current
  attempt's `attempt` and `lease_until` beside it
  (`Arca.Execution.list_stale_running/2`). Answers whether it lapsed.
  """
  @spec lapse(map()) :: boolean()
  def lapse(record) do
    Cyfr.ControlPlane.owner?() and lapse_owned(record)
  end

  defp lapse_owned(record) do
    now = DateTime.utc_now()
    duration_ms = DateTime.diff(now, record.started_at, :millisecond)

    {count, event_seq} =
      Arca.Execution.mark_failed_if_running(
        record.id,
        %{completed_at: now, duration_ms: duration_ms, error_message: @message},
        attempt: record.attempt,
        lease_until: record.lease_until,
        event: "execution.lapsed"
      )

    if count > 0 do
      Logger.info("[Cyfr.Execution.Lapse] #{record.id} lapsed after #{duration_ms}ms")
      Telemetry.row_failed(record, @message, duration_ms)

      Events.publish(record.id, record, "execution.lapsed", event_seq, %{
        "status" => "failed",
        "error" => @message
      })

      if record.component_type in ["formula", "agent"] do
        Cascade.fail_children_of(record.id)
      end
    end

    count > 0
  rescue
    exception ->
      Logger.error(
        "[Cyfr.Execution.Lapse] #{record.id} could not be lapsed: #{Exception.message(exception)}"
      )

      false
  catch
    :exit, reason ->
      Logger.error("[Cyfr.Execution.Lapse] #{record.id} could not be lapsed: #{inspect(reason)}")
      false
  end

  @doc """
  Lapse each of `attempts` that was dispatched to the worker service
  `service_id` (nil for one the control plane holds itself) on its boot
  `boot_id`, is claimed by `runner` when one is given, and still owns its
  running execution. `{:error, :unavailable}` when the store cannot list
  them.
  """
  @spec dispatched(String.t() | nil, String.t(), String.t() | nil, [String.t()]) ::
          :ok | {:error, :unavailable}
  def dispatched(service_id, boot_id, runner, attempts)
      when is_binary(boot_id) and is_list(attempts) do
    case Arca.Execution.list_running_dispatched(attempts, service_id, boot_id, runner) do
      records when is_list(records) ->
        Enum.each(records, &lapse/1)

      {:error, _reason} ->
        {:error, :unavailable}
    end
  catch
    :exit, reason ->
      Logger.error("[Cyfr.Execution.Lapse] attempts of #{boot_id} not listed: #{inspect(reason)}")

      {:error, :unavailable}
  end
end
