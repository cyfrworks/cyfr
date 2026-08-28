# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.LoggerContext do
  @moduledoc """
  Sets Logger.metadata for structured logging with tenant context.

  Metadata is propagated via the process dictionary, so all downstream
  Logger calls in the same process automatically include it. Inject at
  request entry points (plugs, LiveView on_mount, task spawns).

  Log aggregators (Datadog, Splunk, ELK) can filter by these fields
  without regex parsing.

  This module also names the roster it sets — `keys/0`. Config files run
  before application code is loaded and so must spell the list literally;
  `Cyfr.LoggerRosterTest` binds the two together, and `Cyfr.JsonFormatter`
  falls back to it.
  """

  # Every key this module ever sets. A key the formatter's roster omits is
  # written to the process dictionary and then dropped on the floor, which
  # reads exactly like the value being nil.
  @keys [:request_id, :user_id, :athanor_id, :auth_method, :execution_id]

  @doc "The metadata keys this module sets, which the log roster must carry."
  @spec keys() :: [atom()]
  def keys, do: @keys

  @doc """
  Set Logger metadata from a Sanctum.Context struct.

  Call this at request entry points after building the context.
  """
  def set_from_context(%Sanctum.Context{} = ctx) do
    Logger.metadata(
      user_id: ctx.user_id,
      athanor_id: ctx.athanor_id,
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
  Set the execution_id in Logger metadata.

  The executor stamps it when an execution pipeline is built, so every
  log line the run produces correlates to its execution record — the
  same first-class correlator the events and rows already carry.
  """
  def set_execution_id(execution_id) when is_binary(execution_id) do
    Logger.metadata(execution_id: execution_id)
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
