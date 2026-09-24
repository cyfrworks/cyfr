# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.Lapse do
  @moduledoc """
  Ends a running execution whose attempt stopped without closing it.

  A lapse closes the attempt `lapsed` with outcome `uncertain`, fenced on
  the attempt and the lease that was seen, so a renewal that landed since
  matches nothing; fails the row with an `execution.lapsed` event, fires
  the failure telemetry, publishes the event, and fails the children a
  formula or a turn root leaves running (`Crucible.Cascade`).

  Four things find such an attempt: the sweeper, by its lapsed lease
  (`Crucible.Sweeper`); a worker service's report that a runner
  exited, by the attempts it was started with
  (`Crucible.Host.runner_exited/2`); the worker watch, by the boot
  it stopped hearing from or saw replaced
  (`Crucible.WorkerWatch`); and an attempt whose waiter exited, by
  its own id (`Crucible.Attempt`).

  A boot that does not hold the control plane (`Arca.ControlPlane.held?/0`)
  lapses nothing: the rows are the holder's to settle.
  """

  require Logger

  alias Crucible.{Cascade, Events, Telemetry}

  @message "Execution terminated: runner stopped without cleanup"

  @doc """
  Lapse the execution of `record` — the row's map with its current
  attempt's `attempt` and `lease_until` beside it
  (`Arca.Execution.list_stale_running/2`). Answers whether it lapsed.
  """
  @spec lapse(map()) :: boolean()
  def lapse(record) do
    Arca.ControlPlane.held?() and lapse_owned(record)
  end

  defp lapse_owned(record) do
    now = DateTime.utc_now()
    duration_ms = DateTime.diff(now, record.started_at, :millisecond)

    # A lapse retires work: it needs the attempt's stored stamp, never a
    # grant that still stands (`Cyfr.Boundaries.system_responsibilities/0`).
    {count, event_seq} =
      Arca.Execution.mark_failed_if_running(
        record.id,
        %{completed_at: now, duration_ms: duration_ms, error_message: @message},
        attempt: record.attempt,
        lease_until: record.lease_until,
        event: "execution.lapsed",
        grant: stamp(record),
        verify: &Sanctum.ExecutionStanding.stamp_only/1
      )

    if count > 0 do
      Logger.info("[Crucible.Lapse] #{record.id} lapsed after #{duration_ms}ms")
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
        "[Crucible.Lapse] #{record.id} could not be lapsed: #{Exception.message(exception)}"
      )

      false
  catch
    :exit, reason ->
      Logger.error("[Crucible.Lapse] #{record.id} could not be lapsed: #{inspect(reason)}")
      false
  end

  # The stamp the lapsing attempt carries, as the scan read it.
  defp stamp(%{athanor_id: athanor_id, athanor_generation: generation}) do
    case Prima.ExecutionGrant.new(athanor_id, generation) do
      {:ok, grant} -> grant
      {:error, :invalid_grant} -> :stored
    end
  end

  defp stamp(_record), do: :stored

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
    case listed(service_id, boot_id, runner, attempts) do
      {:ok, _lapsed} -> :ok
      {:error, :unavailable} = unavailable -> unavailable
    end
  end

  @doc """
  Lapse each of `attempts` that was dispatched to the worker service
  `service_id` on its boot `boot_id`, whichever runner claimed it, and
  still owns its running execution: what a boot that is gone means for
  them (`Crucible.WorkerWatch`). Answers the records it lapsed, each
  as `Arca.Execution.list_running_dispatched/4` lists it, so the caller can
  stop the attempt process open for each; `{:error, :unavailable}` when the
  store cannot list them.
  """
  @spec boot(String.t(), String.t(), [String.t()]) :: {:ok, [map()]} | {:error, :unavailable}
  def boot(service_id, boot_id, attempts)
      when is_binary(service_id) and is_binary(boot_id) and is_list(attempts) do
    listed(service_id, boot_id, nil, attempts)
  end

  defp listed(_service_id, _boot_id, _runner, []), do: {:ok, []}

  defp listed(service_id, boot_id, runner, attempts) do
    case Arca.Execution.list_running_dispatched(attempts, service_id, boot_id, runner) do
      records when is_list(records) ->
        {:ok, Enum.filter(records, &lapse/1)}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  catch
    :exit, reason ->
      Logger.error("[Crucible.Lapse] attempts of #{boot_id} not listed: #{inspect(reason)}")

      {:error, :unavailable}
  end
end
