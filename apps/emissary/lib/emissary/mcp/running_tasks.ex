defmodule Emissary.MCP.RunningTasks do
  @moduledoc """
  Tracks running tool executions by MCP request ID for cancellation support.

  Uses an ETS table to store `{request_id, task_pid}` mappings so that
  `notifications/cancelled` can shut down in-flight tool executions.
  """

  @table __MODULE__

  @doc """
  Initialize the ETS table. Called from application startup.
  """
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ok
  end

  @doc """
  Register a running task for a given MCP request ID.
  """
  def register(request_id, %Task{pid: pid}) when is_binary(request_id) or is_integer(request_id) do
    :ets.insert(@table, {request_id, pid})
    :ok
  end

  @doc """
  Unregister a task after it completes.
  """
  def unregister(request_id) when is_binary(request_id) or is_integer(request_id) do
    :ets.delete(@table, request_id)
    :ok
  end

  @doc """
  Cancel a running task by its MCP request ID.

  Returns `:ok` if found and cancelled, `{:error, :not_found}` if no task is running.
  """
  def cancel(request_id) do
    case :ets.lookup(@table, request_id) do
      [{^request_id, pid}] ->
        Process.exit(pid, :cancelled)
        :ets.delete(@table, request_id)
        :ok

      [] ->
        {:error, :not_found}
    end
  end
end
