defmodule Cyfr.LoggerContext do
  @moduledoc """
  Sets Logger.metadata for structured logging with tenant context.

  Metadata is propagated via the process dictionary, so all downstream
  Logger calls in the same process automatically include it. Inject at
  request entry points (plugs, LiveView on_mount, task spawns).

  Log aggregators (Datadog, Splunk, ELK) can filter by these fields
  without regex parsing.
  """

  require Logger

  @doc """
  Set Logger metadata from a Sanctum.Context struct.

  Call this at request entry points after building the context.
  """
  def set_from_context(%Sanctum.Context{} = ctx) do
    Logger.metadata(
      user_id: ctx.user_id,
      org_id: ctx.org_id,
      project_id: ctx.project_id,
      auth_method: ctx.auth_method
    )
  end

  @doc """
  Set the request_id in Logger metadata.
  """
  def set_request_id(request_id) when is_binary(request_id) do
    Logger.metadata(request_id: request_id)
  end

  @doc """
  Capture current Logger metadata for propagation to spawned processes.

  Task.Supervisor.start_child does NOT inherit Logger metadata from the
  parent process. Capture before spawn and re-set inside the task.

  ## Usage

      metadata = Cyfr.LoggerContext.capture()
      Task.Supervisor.start_child(MySupervisor, fn ->
        Cyfr.LoggerContext.restore(metadata)
        # ... task work ...
      end)
  """
  def capture do
    Logger.metadata()
  end

  @doc """
  Restore previously captured Logger metadata in a spawned process.
  """
  def restore(metadata) when is_list(metadata) do
    Logger.metadata(metadata)
  end
end
