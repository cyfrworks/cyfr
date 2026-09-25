# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.Telemetry do
  @moduledoc """
  The lifecycle telemetry of an execution — its start, its completion and
  its failure — and the events its guest pushes to a stream.

  The lifecycle events are audit-bearing — `Arca.AuditHandler` and
  `Cyfr.TelemetryBridge` consume them (`Cyfr.Telemetry.Catalog`) — and are
  distinct from the execution's persistent record (`Crucible.Record`).
  `[:cyfr, :opus, :emit]` is for operator metrics. The events a running
  component's storage, tool and formula calls produce are
  `Opus.Telemetry`'s.

  ## Events

  - `[:cyfr, :opus, :execute, :start]` - an execution begins
  - `[:cyfr, :opus, :execute, :stop]` - an execution completes
  - `[:cyfr, :opus, :execute, :exception]` - an execution fails, or its row
    is failed from outside: a child by its parent's cascade, a lapsed row
    by the sweeper; or a caller cancelled it (`status: :cancelled`)
  - `[:cyfr, :opus, :emit]` - a guest's event is pushed to an execution's stream

  ## Measurements

  | Event | Measurements |
  |-------|-------------|
  | `:start` | `%{system_time: integer}` |
  | `:stop` | `%{duration: integer, memory_bytes: integer (when reported)}` |
  | `:exception` | `%{duration: integer}`; `system_time` too for a row failed from outside |

  `duration` is in native units (nanoseconds).

  ## Metadata

  Every lifecycle event carries:
  - `execution_id` - Unique execution identifier (exec_<uuid7>)
  - `component` - Component reference
  - `component_type` - :catalyst, :reagent, or :formula
  - `user_id` - User who initiated the execution
  - `athanor_id` - The athanor the execution runs in
  - `outcome` - :success or :failure (stop/exception only)
  """

  alias Crucible.Record

  @doc """
  Emit `[:cyfr, :opus, :execute, :start]` when an execution's row is
  admitted, before any component code runs.

  Measurements: `system_time`. Metadata: `execution_id`, `request_id`,
  `component`, `reference`, `component_type`, `user_id`, `athanor_id`.
  """
  @spec execute_start(Record.t()) :: :ok
  def execute_start(%Record{} = record) do
    :telemetry.execute(
      [:cyfr, :opus, :execute, :start],
      %{system_time: System.system_time()},
      %{
        execution_id: record.id,
        request_id: record.request_id,
        component: format_reference(record.reference),
        reference: record.reference,
        component_type: record.component_type,
        user_id: record.user_id,
        athanor_id: record.athanor_id
      }
    )
  end

  @doc """
  Emit `[:cyfr, :opus, :execute, :stop]` for a record marked completed.

  Measurements: `duration`, and `memory_bytes` only when `measurements`
  carries it. Metadata: that of `execute_start/1`, plus
  `parent_execution_id` (nil for a root), `outcome: :success` and
  `duration_ms`.
  """
  @spec execute_stop(Record.t(), map()) :: :ok
  def execute_stop(%Record{} = record, measurements \\ %{}) do
    :telemetry.execute(
      [:cyfr, :opus, :execute, :stop],
      # Only real measurements ride: memory is included when the runtime
      # reports one, never fabricated as zero.
      Map.merge(%{duration: native_duration(record)}, Map.take(measurements, [:memory_bytes])),
      %{
        execution_id: record.id,
        request_id: record.request_id,
        component: format_reference(record.reference),
        reference: record.reference,
        component_type: record.component_type,
        user_id: record.user_id,
        athanor_id: record.athanor_id,
        # nil for a root; a chain's children name their parent, so a tray
        # counts a piece of work once.
        parent_execution_id: record.parent_execution_id,
        outcome: :success,
        duration_ms: record.duration_ms
      }
    )
  end

  @doc """
  Emit `[:cyfr, :opus, :execute, :exception]` for a record marked failed.

  Measurements: `duration`. Metadata: that of `execute_start/1`, plus
  `parent_execution_id` (nil for a root), `outcome: :failure`, `error`
  (`reason` itself when a string, else inspected) and `duration_ms`.
  """
  @spec execute_exception(Record.t(), term()) :: :ok
  def execute_exception(%Record{} = record, reason) do
    :telemetry.execute(
      [:cyfr, :opus, :execute, :exception],
      %{duration: native_duration(record)},
      %{
        execution_id: record.id,
        request_id: record.request_id,
        component: format_reference(record.reference),
        reference: record.reference,
        component_type: record.component_type,
        user_id: record.user_id,
        athanor_id: record.athanor_id,
        # nil for a root; a chain's children name their parent, so a tray
        # counts a piece of work once.
        parent_execution_id: record.parent_execution_id,
        outcome: :failure,
        error: format_error(reason),
        duration_ms: record.duration_ms
      }
    )
  end

  @doc """
  Emit `[:cyfr, :opus, :execute, :exception]` for a record a caller
  cancelled, after the cancel's write: the record's `execution_id`,
  `request_id`, `component`, `reference`, `component_type`, `athanor_id`,
  `parent_execution_id` and `duration_ms`, with `user_id` the person the
  cancel ran as (`cancelled_by`, the server's own work names `"system"`),
  `error: "cancelled"` and `status: :cancelled`, so the bridge announces a
  cancel and not a failure.
  """
  @spec execute_cancelled(Record.t(), String.t() | nil) :: :ok
  def execute_cancelled(%Record{} = record, cancelled_by) do
    :telemetry.execute(
      [:cyfr, :opus, :execute, :exception],
      %{duration: native_duration(record), system_time: System.system_time()},
      %{
        execution_id: record.id,
        request_id: record.request_id,
        component: format_reference(record.reference),
        reference: record.reference,
        component_type: record.component_type,
        user_id: cancelled_by,
        athanor_id: record.athanor_id,
        parent_execution_id: record.parent_execution_id,
        error: "cancelled",
        status: :cancelled,
        duration_ms: record.duration_ms
      }
    )
  end

  @doc """
  Emit `[:cyfr, :opus, :execute, :exception]` for an execution row failed
  from outside its runner — a child failed by its parent's cascade, or a
  lapsed row the sweeper retired — after the write that failed it.

  `row` is the stored execution (`Arca.Execution`, or the sweeper's scan
  of it); its `component_type` column is reported as its executable type,
  `:reagent` when it names none. Measurements: `duration` and
  `system_time`. Metadata: `execution_id`, `request_id`, `component` and
  `reference` (both the stored reference), `component_type`, `user_id`,
  `athanor_id`, `outcome: :failure`, `error` and `duration_ms`.
  """
  @spec row_failed(map(), String.t(), non_neg_integer()) :: :ok
  def row_failed(row, error, duration_ms) do
    component_type =
      case Record.executable_type(row.component_type) do
        {:ok, type} -> type
        :error -> :reagent
      end

    :telemetry.execute(
      [:cyfr, :opus, :execute, :exception],
      %{duration: duration_ms * 1_000_000, system_time: System.system_time()},
      %{
        execution_id: row.id,
        request_id: row.request_id,
        component: row.reference,
        reference: row.reference,
        component_type: component_type,
        user_id: row.user_id,
        athanor_id: row.athanor_id,
        outcome: :failure,
        error: error,
        duration_ms: duration_ms
      }
    )
  end

  @doc """
  Emit `[:cyfr, :opus, :emit]` when a guest's event is pushed to the stream
  of `execution_id` under `sequence`.

  Measurements: `system_time`, `sequence`. Metadata: `execution_id`.
  """
  @spec emit(String.t(), String.t()) :: :ok
  def emit(execution_id, sequence) do
    :telemetry.execute(
      [:cyfr, :opus, :emit],
      %{system_time: System.system_time(), sequence: sequence},
      %{execution_id: execution_id}
    )
  end

  defp native_duration(%Record{duration_ms: duration_ms}), do: (duration_ms || 0) * 1_000_000

  defp format_reference(ref) when is_binary(ref), do: ref
  defp format_reference(_), do: "unknown"

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: Grimoire.render(reason)
end
