# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Telemetry do
  @moduledoc """
  The operational telemetry of a running component: its storage and tool
  calls and its formula concurrency.

  These events are for operator metrics; the audit-bearing lifecycle of an
  execution — start, stop, exception — and the events a guest pushes to
  its stream are CYFR's, recorded where the attempt is closed and where
  its deltas are numbered.

  ## Events

  - `[:cyfr, :opus, :formula, :spawn]` - Emitted when a task is spawned via `spawn`
  - `[:cyfr, :opus, :formula, :await]` - Emitted when a task is awaited (with duration, status)
  - `[:cyfr, :opus, :formula, :await_all]` - Emitted when batch await completes (with count, timed_out count)
  - `[:cyfr, :opus, :formula, :await_any]` - Emitted when race completes (with winner task_id)
  - `[:cyfr, :opus, :formula, :cancel]` - Emitted when a spawned task is cancelled
  - `[:cyfr, :opus, :mcp_tool, :call]` - Emitted when a formula calls an MCP tool via host function
  - `[:cyfr, :opus, :storage, :call]` - Emitted when a catalyst calls a storage operation via host function
  """

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
end
