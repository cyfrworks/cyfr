defmodule Opus.Telemetry do
  @moduledoc """
  Telemetry events for Opus execution engine.

  Emits standardized telemetry events per PRD §5.9.8 for operational monitoring
  and alerting. Telemetry is distinct from logging (persistent records in Arca)
  and forensic replay (complete state capture).

  ## Events

  - `[:cyfr, :opus, :execute, :start]` - Emitted when execution begins
  - `[:cyfr, :opus, :execute, :stop]` - Emitted when execution completes successfully
  - `[:cyfr, :opus, :execute, :exception]` - Emitted when execution fails
  - `[:cyfr, :opus, :secret, :accessed]` - Emitted when a secret is accessed via WASI host function
  - `[:cyfr, :opus, :secret, :denied]` - Emitted when a secret access is denied (not granted)
  - `[:cyfr, :opus, :mcp_tool, :call]` - Emitted when a formula calls an MCP tool via host function

  ## Measurements

  | Event | Measurements |
  |-------|-------------|
  | `:start` | `%{system_time: integer}` |
  | `:stop` | `%{duration: integer, memory_bytes: integer}` |
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
        component: format_reference(record.reference),
        component_type: record.component_type,
        user_id: record.user_id
      }
    )
  end

  @doc """
  Emit `[:cyfr, :opus, :execute, :stop]` event when execution completes successfully.

  Call this after WASM execution completes and the record is marked as completed.

  ## Measurements

  - `duration` - Execution duration in native time units
  - `memory_bytes` - Peak memory usage during execution (0 if unknown)

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
    duration_native = (record.duration_ms || 0) * 1_000_000  # ms to native (nanoseconds)
    memory_bytes = Map.get(measurements, :memory_bytes, 0)

    :telemetry.execute(
      [:cyfr, :opus, :execute, :stop],
      %{duration: duration_native, memory_bytes: memory_bytes},
      %{
        execution_id: record.id,
        component: format_reference(record.reference),
        component_type: record.component_type,
        user_id: record.user_id,
        outcome: :success
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
        component: format_reference(record.reference),
        component_type: record.component_type,
        user_id: record.user_id,
        outcome: :failure,
        error: format_error(reason)
      }
    )
  end

  @doc """
  Emit `[:cyfr, :opus, :formula, :invoke]` event when a formula invokes a sub-component.

  ## Measurements

  - `system_time` - System time when invocation occurred (native time unit)

  ## Metadata

  - `parent_execution_id` - The formula's execution ID
  - `child_execution_id` - The sub-component's execution ID
  - `component_ref` - The sub-component reference string
  - `status` - Outcome (:ok or :error)
  """
  @spec formula_invoke(String.t(), String.t() | nil, String.t(), atom()) :: :ok
  def formula_invoke(parent_execution_id, child_execution_id, component_ref, status) do
    :telemetry.execute(
      [:cyfr, :opus, :formula, :invoke],
      %{system_time: System.system_time()},
      %{
        parent_execution_id: parent_execution_id,
        child_execution_id: child_execution_id,
        component_ref: component_ref,
        status: status
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

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp format_reference(%{"oci" => ref}), do: ref
  defp format_reference(%{"local" => path}), do: "local:#{Path.basename(path)}"
  defp format_reference(%{"arca" => path}), do: "arca:#{path}"
  defp format_reference(ref) when is_map(ref), do: inspect(ref)
  defp format_reference(_), do: "unknown"

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
