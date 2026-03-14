defmodule Emissary.MCP.RunningTasks do
  @moduledoc """
  Tracks running tool executions by MCP request ID for cancellation support.

  Uses an ETS table to store `{request_id, task_pid, user_id}` tuples so that
  `notifications/cancelled` can shut down in-flight tool executions with
  ownership verification.
  """

  require Logger

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
  Register a running task for a given MCP request ID, tracking the owning user.
  """
  def register(request_id, %Task{pid: pid}, user_id \\ nil)
      when is_binary(request_id) or is_integer(request_id) do
    :ets.insert(@table, {request_id, pid, user_id})
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
  Cancel a running task by its MCP request ID with ownership verification.

  Only the user who owns the task (or an admin with wildcard permissions) can cancel it.
  Returns `:ok` if found and cancelled, `{:error, :not_found}` if no task is running,
  or `{:error, :unauthorized}` if the caller doesn't own the task.
  """
  def cancel(request_id, %Sanctum.Context{} = ctx) do
    case :ets.lookup(@table, request_id) do
      [{^request_id, pid, owner_id}] ->
        if authorized_to_cancel?(ctx, owner_id) do
          Process.exit(pid, :cancelled)
          :ets.delete(@table, request_id)
          :ok
        else
          Logger.warning(
            "[RunningTasks] Unauthorized cancel attempt: " <>
              "user=#{ctx.user_id} request_id=#{request_id} owner=#{owner_id}"
          )

          {:error, :unauthorized}
        end

      [] ->
        {:error, :not_found}
    end
  end


  # Admin or wildcard users can cancel any task
  defp authorized_to_cancel?(%Sanctum.Context{} = ctx, owner_id) do
    ctx.user_id == owner_id or
      Sanctum.Context.has_permission?(ctx, :*) or
      Sanctum.Context.has_permission?(ctx, :admin)
  end
end
