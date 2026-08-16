# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Telemetry do
  @moduledoc """
  Telemetry events for Opus execution engine.

  Emits standardized telemetry events for operational monitoring
  and alerting. Telemetry is distinct from logging (persistent records in Arca)
  and forensic replay (complete state capture).

  ## Events

  - `[:cyfr, :opus, :execute, :start]` - Emitted when execution begins
  - `[:cyfr, :opus, :execute, :stop]` - Emitted when execution completes successfully
  - `[:cyfr, :opus, :execute, :exception]` - Emitted when execution fails
  - `[:cyfr, :opus, :secret, :accessed]` - Emitted when a secret is accessed via WASI host function
  - `[:cyfr, :opus, :secret, :denied]` - Emitted when a secret access is denied (not granted)
  - `[:cyfr, :opus, :formula, :spawn]` - Emitted when a task is spawned via `spawn`
  - `[:cyfr, :opus, :formula, :await]` - Emitted when a task is awaited (with duration, status)
  - `[:cyfr, :opus, :formula, :await_all]` - Emitted when batch await completes (with count, timed_out count)
  - `[:cyfr, :opus, :formula, :await_any]` - Emitted when race completes (with winner task_id)
  - `[:cyfr, :opus, :formula, :cancel]` - Emitted when a spawned task is cancelled
  - `[:cyfr, :opus, :formula, :emit]` - Emitted when a formula pushes an intermediate event via `emit`
  - `[:cyfr, :opus, :mcp_tool, :call]` - Emitted when a formula calls an MCP tool via host function
  - `[:cyfr, :opus, :storage, :call]` - Emitted when a catalyst calls a storage operation via host function

  ## Measurements

  | Event | Measurements |
  |-------|-------------|
  | `:start` | `%{system_time: integer}` |
  | `:stop` | `%{duration: integer, memory_bytes: integer (when reported)}` |
  | `:exception` | `%{duration: integer}` |

  ## Metadata

  All events include:
  - `execution_id` - Unique execution identifier (exec_<uuid7>)
  - `component` - Component reference (OCI ref, local path, etc.)
  - `component_type` - :catalyst, :reagent, or :formula
  - `user_id` - User who initiated the execution
  - `outcome` - :success, :failure, or :exception (stop/exception only)

  ## Usage

      # In Opus.MCP run handler:
      record = ExecutionRecord.new(...)
      Opus.Telemetry.execute_start(record)

      case execute(...) do
        {:ok, output} ->
          completed = ExecutionRecord.complete(record, output)
          Opus.Telemetry.execute_stop(completed, %{memory_bytes: memory})

        {:error, reason} ->
          failed = ExecutionRecord.fail(record, reason)
          Opus.Telemetry.execute_exception(failed, reason)
      end

  ## Integration

  Attach handlers in your application supervision tree:

      :telemetry.attach_many(
        "opus-metrics",
        [
          [:cyfr, :opus, :execute, :start],
          [:cyfr, :opus, :execute, :stop],
          [:cyfr, :opus, :execute, :exception]
        ],
        &MyApp.Telemetry.handle_event/4,
        nil
      )

  """

  alias Opus.ExecutionRecord

  @doc """
  Emit `[:cyfr, :opus, :execute, :start]` event when execution begins.

  Call this immediately after creating the ExecutionRecord, before any
  WASM execution occurs.

  ## Measurements

  - `system_time` - System time when execution started (native time unit)

  ## Metadata

  - `execution_id` - The execution record ID
  - `component` - Component reference string
  - `component_type` - :catalyst, :reagent, or :formula
  - `user_id` - User who initiated execution
  """
  @spec execute_start(ExecutionRecord.t()) :: :ok
  def execute_start(%ExecutionRecord{} = record) do
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
  Emit `[:cyfr, :opus, :execute, :stop]` event when execution completes successfully.

  Call this after WASM execution completes and the record is marked as completed.

  ## Measurements

  - `duration` - Execution duration in native time units
  - `memory_bytes` - Peak memory usage, included only when the runtime reports it

  ## Metadata

  - `execution_id` - The execution record ID
  - `component` - Component reference string
  - `component_type` - :catalyst, :reagent, or :formula
  - `user_id` - User who initiated execution
  - `outcome` - :success
  """
  @spec execute_stop(ExecutionRecord.t(), map()) :: :ok
  def execute_stop(%ExecutionRecord{} = record, measurements \\ %{}) do
    # Convert duration_ms to native time units for consistency with :telemetry conventions
    # ms to native (nanoseconds)
    duration_native = (record.duration_ms || 0) * 1_000_000

    :telemetry.execute(
      [:cyfr, :opus, :execute, :stop],
      # Only real measurements ride: memory is included when the runtime
      # reports one, never fabricated as zero.
      Map.merge(%{duration: duration_native}, Map.take(measurements, [:memory_bytes])),
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
  Emit `[:cyfr, :opus, :execute, :exception]` event when execution fails.

  Call this when WASM execution fails for any reason (error, timeout, etc.).

  ## Measurements

  - `duration` - Time until failure in native time units

  ## Metadata

  - `execution_id` - The execution record ID
  - `component` - Component reference string
  - `component_type` - :catalyst, :reagent, or :formula
  - `user_id` - User who initiated execution
  - `outcome` - :failure
  - `error` - Error reason (string)
  """
  @spec execute_exception(ExecutionRecord.t(), term()) :: :ok
  def execute_exception(%ExecutionRecord{} = record, reason) do
    # Convert duration_ms to native time units
    duration_native = (record.duration_ms || 0) * 1_000_000

    :telemetry.execute(
      [:cyfr, :opus, :execute, :exception],
      %{duration: duration_native},
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
  Emit `[:cyfr, :opus, :mcp_tool, :call]` event when a formula calls an MCP tool.

  ## Measurements

  - `duration_ms` - Time taken for the tool call in milliseconds

  ## Metadata

  - `execution_id` - The formula's execution ID
  - `tool_action` - The tool action string (e.g., "component.search")
  - `status` - Outcome (:ok or :error)
  """
  @spec mcp_tool_call(String.t(), String.t(), atom(), non_neg_integer()) :: :ok
  def mcp_tool_call(execution_id, tool_action, status, duration_ms) do
    :telemetry.execute(
      [:cyfr, :opus, :mcp_tool, :call],
      %{duration_ms: duration_ms},
      %{
        execution_id: execution_id,
        tool_action: tool_action,
        status: status
      }
    )
  end

  @doc """
  Emit `[:cyfr, :opus, :storage, :call]` event when a catalyst calls a storage operation.

  ## Measurements

  - `duration_ms` - Time taken for the storage call in milliseconds

  ## Metadata

  - `component_ref` - The catalyst's component reference
  - `action` - The storage action (e.g., "read", "write", "list")
  - `status` - Outcome (:ok or :error)
  """
  @spec storage_call(String.t(), String.t(), atom(), non_neg_integer()) :: :ok
  def storage_call(component_ref, action, status, duration_ms) do
    :telemetry.execute(
      [:cyfr, :opus, :storage, :call],
      %{duration_ms: duration_ms},
      %{
        component_ref: component_ref,
        action: action,
        status: status
      }
    )
  end

  # ===========================================================================
  # Formula Async Primitives
  # ===========================================================================

  @doc """
  Emit `[:cyfr, :opus, :formula, :spawn]` event when a task is spawned.
  """
  @spec formula_spawn(String.t(), String.t(), String.t()) :: :ok
  def formula_spawn(parent_execution_id, task_id, component_ref) do
    :telemetry.execute(
      [:cyfr, :opus, :formula, :spawn],
      %{system_time: System.system_time()},
      %{
        parent_execution_id: parent_execution_id,
        task_id: task_id,
        component_ref: component_ref
      }
    )
  end

  @doc """
  Emit `[:cyfr, :opus, :formula, :await]` event when a task is awaited.
  """
  @spec formula_await(String.t(), atom(), non_neg_integer()) :: :ok
  def formula_await(task_id, status, duration_ms) do
    :telemetry.execute(
      [:cyfr, :opus, :formula, :await],
      %{duration_ms: duration_ms},
      %{
        task_id: task_id,
        status: status
      }
    )
  end

  @doc """
  Emit `[:cyfr, :opus, :formula, :await_all]` event when batch await completes.
  """
  @spec formula_await_all(String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          :ok
  def formula_await_all(parent_execution_id, count, timed_out, duration_ms) do
    :telemetry.execute(
      [:cyfr, :opus, :formula, :await_all],
      %{duration_ms: duration_ms},
      %{
        parent_execution_id: parent_execution_id,
        count: count,
        timed_out: timed_out
      }
    )
  end

  @doc """
  Emit `[:cyfr, :opus, :formula, :cancel]` event when a task is cancelled.
  """
  @spec formula_cancel(String.t(), String.t()) :: :ok
  def formula_cancel(parent_execution_id, task_id) do
    :telemetry.execute(
      [:cyfr, :opus, :formula, :cancel],
      %{system_time: System.system_time()},
      %{
        parent_execution_id: parent_execution_id,
        task_id: task_id
      }
    )
  end

  @doc """
  Emit `[:cyfr, :opus, :formula, :emit]` event when a formula pushes an intermediate event.
  """
  @spec formula_emit(String.t(), non_neg_integer()) :: :ok
  def formula_emit(execution_id, sequence) do
    :telemetry.execute(
      [:cyfr, :opus, :formula, :emit],
      %{system_time: System.system_time(), sequence: sequence},
      %{execution_id: execution_id}
    )
  end

  @doc """
  Emit `[:cyfr, :opus, :formula, :await_any]` event when race completes.
  """
  @spec formula_await_any(String.t(), String.t() | nil, non_neg_integer()) :: :ok
  def formula_await_any(parent_execution_id, winner_task_id, duration_ms) do
    :telemetry.execute(
      [:cyfr, :opus, :formula, :await_any],
      %{duration_ms: duration_ms},
      %{
        parent_execution_id: parent_execution_id,
        winner_task_id: winner_task_id
      }
    )
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp format_reference(ref) when is_binary(ref), do: ref
  defp format_reference(_), do: "unknown"

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
