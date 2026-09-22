# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.LoggerContext do
  @moduledoc """
  Shared runtime helpers for Logger process metadata and its key vocabulary.
  Lower applications and trust islands call these helpers without a Host edge.

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

  @typedoc """
  The caller a request runs as: any map carrying these keys, such as a
  `Sanctum.Context`.
  """
  @type caller :: %{
          :user_id => String.t() | nil,
          :athanor_id => String.t() | nil,
          :auth_method => atom(),
          optional(atom()) => term()
        }

  @doc """
  Set Logger metadata from the request's caller.

  Call this at request entry points after building the context.
  """
  @spec set_from_context(caller()) :: :ok
  def set_from_context(%{user_id: user_id, athanor_id: athanor_id, auth_method: auth_method}) do
    Logger.metadata(user_id: user_id, athanor_id: athanor_id, auth_method: auth_method)
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
