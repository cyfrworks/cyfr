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

  `unexpected/3` is the one log line for a process's unexpected-message
  catch-all. Each server keeps its own final `handle_info/2` clause and
  calls it there.
  """

  require Logger

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

  @levels [:debug, :info, :warning, :error]

  # The whole line, prefix included. A catch-all receives whatever reached
  # the mailbox, so the line has one size whatever the message's.
  @max_line 200

  # A map names at most this many of its keys.
  @max_keys 10

  @doc """
  Log an unexpected message at `level`, by its shape and never its values.

  The line reads `[Module] unexpected message: <shape>`, at most
  #{@max_line} characters. The shape of a tuple is its leading atom and
  its arity; of a struct, its module and sorted field keys; of a map, its
  size and its first #{@max_keys} sorted keys, an atom key as itself and
  any other key by its type; an atom is itself; a pid,
  reference, port or function is its type; anything else is its type and
  size. A message routinely carries thread rows, execution output or a
  credential, and none of that reaches the log.

  ## Level

  Defaults to `:warning`: a supervised server receiving a message it does
  not understand is a wiring fault worth seeing.

  Console LiveViews pass `:debug`. A LiveView subscribes to tenant-wide
  topics and is expected to receive broadcasts meant for its siblings; at
  `:warning` every such message would be an alarm about normal operation.
  """
  @spec unexpected(module(), term(), :debug | :info | :warning | :error) :: :ok
  def unexpected(module, message, level \\ :warning)
      when is_atom(module) and level in @levels do
    line = "[#{inspect(module)}] unexpected message: " <> shape(message)
    Logger.log(level, cap(line, @max_line))
  end

  defp shape(atom) when is_atom(atom), do: inspect(atom)

  defp shape(tuple) when is_tuple(tuple) do
    case tuple_size(tuple) do
      0 -> "tuple/0"
      arity when is_atom(elem(tuple, 0)) -> "tuple #{inspect(elem(tuple, 0))}/#{arity}"
      arity -> "tuple/#{arity}"
    end
  end

  defp shape(%module{} = struct) do
    keys = struct |> Map.keys() |> List.delete(:__struct__) |> Enum.sort()
    "%#{inspect(module)}{#{Enum.map_join(keys, ", ", &key/1)}}"
  end

  defp shape(map) when is_map(map) do
    keys = map |> Map.keys() |> Enum.sort() |> Enum.take(@max_keys)
    "map/#{map_size(map)} [#{Enum.map_join(keys, ", ", &key/1)}]"
  end

  defp shape(binary) when is_binary(binary), do: "binary/#{byte_size(binary)} bytes"
  defp shape(bits) when is_bitstring(bits), do: "bitstring/#{bit_size(bits)} bits"
  defp shape(list) when is_list(list), do: "list/#{count(list, 0)}"
  defp shape(other), do: type(other)

  # An atom key names a field. Any other key is data, a credential
  # possibly, and is only its type.
  defp key(atom) when is_atom(atom), do: inspect(atom)
  defp key(other), do: type(other)

  defp type(term) when is_tuple(term), do: "tuple"
  defp type(term) when is_map(term), do: "map"
  defp type(term) when is_list(term), do: "list"
  defp type(term) when is_binary(term), do: "binary"
  defp type(term) when is_bitstring(term), do: "bitstring"
  defp type(term) when is_integer(term), do: "integer"
  defp type(term) when is_float(term), do: "float"
  defp type(term) when is_pid(term), do: "pid"
  defp type(term) when is_reference(term), do: "reference"
  defp type(term) when is_port(term), do: "port"
  defp type(term) when is_function(term), do: "function"

  # An improper list has no length; its proper prefix is what is counted.
  defp count([_ | rest], n), do: count(rest, n + 1)
  defp count(_tail, n), do: n

  defp cap(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end
end
