# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Lapse do
  @moduledoc """
  Ends a running execution whose attempt stopped without closing it.

  A lapse closes the attempt `lapsed` with outcome `uncertain`, fenced on
  the attempt and the lease that was seen, so a renewal that landed since
  matches nothing; fails the row with an `execution.lapsed` event, fires
  the failure telemetry, publishes the event, and fails the children a
  formula or a turn root leaves running (`Opus.Cascade`).

  Four things find such an attempt: the sweeper, by its lapsed lease
  (`Opus.Sweeper`); a worker service's report that a runner
  exited, by the attempts it was started with
  (`Opus.Host.runner_exited/2`); the worker watch, by the boot
  it stopped hearing from or saw replaced
  (`Opus.WorkerWatch`); and an attempt whose waiter exited, by
  its own id (`Opus.Attempt`).

  A lapse says "Execution terminated: runner stopped without cleanup", but
  one of a report whose runner the kernel ended for memory says that, by
  the limit that ended it (`ended_for_memory/1`).

  A boot that does not hold the control plane (`Arca.ControlPlane.held?/0`)
  lapses nothing: the rows are the holder's to settle.
  """

  require Logger

  alias Opus.{Cascade, Events, Telemetry}

  @message "Execution terminated: runner stopped without cleanup"

  @doc """
  Lapse the execution of `record` — the row's map with its current
  attempt's `attempt` and `lease_until` beside it
  (`Arca.Execution.list_stale_running/2`). Answers whether it lapsed.
  """
  @spec lapse(map()) :: boolean()
  def lapse(record), do: lapse(record, @message)

  defp lapse(record, message) do
    Arca.ControlPlane.held?() and lapse_owned(record, message)
  end

  @doc """
  What a run says whose runner the kernel ended for memory, by the limit
  that ended it (`t:Prima.HostAPI.memory_end/0`): `Prima.Refusal`'s
  sentence for `{:memory, "The run", cause}`.
  """
  @spec ended_for_memory(:cap | :machine | :either) :: String.t()
  def ended_for_memory(cause) when cause in [:cap, :machine, :either],
    do: Prima.Refusal.message({:memory, "The run", cause})

  defp lapse_owned(record, message) do
    now = DateTime.utc_now()
    duration_ms = DateTime.diff(now, record.started_at, :millisecond)

    case fail_row(record, message, now, duration_ms) do
      {:ok, 0, _event_seq, _closed_questions} ->
        false

      {:ok, _count, event_seq, closed_questions} ->
        lapsed(record, message, event_seq, closed_questions, now, duration_ms)
        true

      :error ->
        false
    end
  end

  # A lapse retires work: it needs the attempt's stored stamp, never a
  # grant that still stands (`Cyfr.Boundaries.system_responsibilities/0`).
  # A failure here commits nothing, and the lapse did not happen.
  defp fail_row(record, message, now, duration_ms) do
    {count, event_seq, closed_questions} =
      Arca.Execution.mark_failed_if_running(
        record.id,
        %{
          completed_at: now,
          duration_ms: duration_ms,
          error_message: message,
          error_class: "uncertain"
        },
        attempt: record.attempt,
        lease_until: record.lease_until,
        grant: stamp(record),
        verify: &Sanctum.ExecutionStanding.stamp_only/1
      )

    {:ok, count, event_seq, closed_questions}
  rescue
    exception ->
      Logger.error(
        "[Opus.Lapse] #{record.id} could not be lapsed: #{Prima.LogFilter.exception_message(exception)}"
      )

      :error
  catch
    :exit, reason ->
      Logger.error(
        "[Opus.Lapse] #{record.id} could not be lapsed: #{Prima.LogFilter.inspect_reason(reason)}"
      )

      :error
  end

  # The row is failed: the lapse stands done whatever follows. Its
  # telemetry, its event and its children's failure each run whatever the
  # one before it did, so a publication that cannot be made never leaves a
  # formula's children running.
  defp lapsed(record, message, event_seq, closed_questions, now, duration_ms) do
    Logger.info("[Opus.Lapse] #{record.id} lapsed after #{duration_ms}ms")

    after_commit(record, "questions", fn ->
      Opus.Record.questions_ended(record.athanor_id, closed_questions)
    end)

    after_commit(record, "telemetry", fn ->
      Telemetry.row_failed(record, %{
        error: message,
        error_class: :uncertain,
        ended_at: now,
        duration_ms: duration_ms
      })
    end)

    after_commit(record, "event", fn ->
      Events.publish(record.id, record, "execution.lapsed", event_seq, %{
        "status" => "failed",
        "error" => message
      })
    end)

    if record.component_type in ["formula", "agent"] do
      after_commit(record, "children's failure", fn ->
        Cascade.fail_children_of(record.id)
      end)
    end
  end

  defp after_commit(record, what, fun) do
    fun.()
  rescue
    exception ->
      Logger.error(
        "[Opus.Lapse] #{record.id} lapsed, but its #{what} failed: " <>
          Prima.LogFilter.exception_message(exception)
      )
  catch
    :exit, reason ->
      Logger.error(
        "[Opus.Lapse] #{record.id} lapsed, but its #{what} failed: " <>
          Prima.LogFilter.inspect_reason(reason)
      )
  end

  # The stamp the lapsing attempt carries, as the scan read it. Both
  # columns are required of every attempt row; a row without a valid
  # stamp is damaged, and its lapse fails (logged above) rather than
  # writing under another stamp.
  defp stamp(%{athanor_id: athanor_id, athanor_generation: generation}) do
    {:ok, grant} = Prima.ExecutionGrant.new(athanor_id, generation)
    grant
  end

  @doc """
  Lapse each of `attempts` that was dispatched to the worker service
  `service_id` (nil for one the control plane holds itself) on its boot
  `boot_id`, is claimed by `runner` when one is given, and still owns its
  running execution, saying that it ran out of memory where `memory`, a
  report's, names the limit that ended its runner
  (`ended_for_memory/1`). `{:error, :unavailable}` when the store cannot
  list them.
  """
  @spec dispatched(
          String.t() | nil,
          String.t(),
          String.t() | nil,
          [String.t()],
          Prima.HostAPI.memory_end()
        ) :: :ok | {:error, :unavailable}
  def dispatched(service_id, boot_id, runner, attempts, memory \\ nil)
      when is_binary(boot_id) and is_list(attempts) do
    message = if memory, do: ended_for_memory(memory), else: @message

    case listed(service_id, boot_id, runner, attempts, message) do
      {:ok, _lapsed} -> :ok
      {:error, :unavailable} = unavailable -> unavailable
    end
  end

  @doc """
  Lapse each of `attempts` that was dispatched to the worker service
  `service_id` on its boot `boot_id`, whichever runner claimed it, and
  still owns its running execution: what a boot that is gone means for
  them (`Opus.WorkerWatch`). Answers the records it lapsed, each
  as `Arca.Execution.list_running_dispatched/4` lists it, so the caller can
  stop the attempt process open for each; `{:error, :unavailable}` when the
  store cannot list them.
  """
  @spec boot(String.t(), String.t(), [String.t()]) :: {:ok, [map()]} | {:error, :unavailable}
  def boot(service_id, boot_id, attempts)
      when is_binary(service_id) and is_binary(boot_id) and is_list(attempts) do
    listed(service_id, boot_id, nil, attempts, @message)
  end

  defp listed(_service_id, _boot_id, _runner, [], _message), do: {:ok, []}

  defp listed(service_id, boot_id, runner, attempts, message) do
    case Arca.Execution.list_running_dispatched(attempts, service_id, boot_id, runner) do
      records when is_list(records) ->
        {:ok, Enum.filter(records, &lapse(&1, message))}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  catch
    :exit, reason ->
      Logger.error(
        "[Opus.Lapse] attempts of #{boot_id} not listed: #{Prima.LogFilter.inspect_reason(reason)}"
      )

      {:error, :unavailable}
  end
end
