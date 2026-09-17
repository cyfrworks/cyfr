# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RunnerControl do
  @moduledoc """
  The local control channel between a worker service and one of its
  runners: the OS process that runs one execution subtree at a time. The
  service holds the channel's one end and the runner the other; the
  keeper that started the runner relays it over the runner's file
  descriptor 3. `tests/fixtures/runner_control.json` holds the vectors
  every encoder and decoder of it must reproduce.

  The service sends `assign` and `cancel_child`; the runner sends
  `complete` and `exit`. Guest data never travels on it: deltas, results,
  host-call bodies and vault fields go between the runner and CYFR over
  the host API (`Cyfr.HostAPI`), under the attempt's keys. What crosses
  here is what `c:Cyfr.WorkerAPI.start/3` was given and what the service
  reports (`c:Cyfr.HostAPI.runner_exited/3`). The channel carries no MAC:
  the keeper's process isolation is its boundary, and nothing on it
  authorizes anything — CYFR verifies the assignment when the runner
  attaches, and the sealed keys open only as the attempt they name.

  ## Frames

  A frame is one JSON object on one line, ending in `\\n`, carrying
  `"v": 1` and a `type`, as the keeper's own protocol does. A line spans
  at most `max_line_bytes/0` bytes before its newline. Members are the
  message's fields and nothing else: an unknown member is refused, a
  missing one is never defaulted. The encoder writes `v`, then `type`,
  then the fields in the order below, so a message always encodes to the
  same line.

  Service to runner:

    * `assign` — run this subtree: the `assignment` (the signed token,
      `t:Cyfr.Assignment.token/0`, opaque here and read by the runner
      with `Cyfr.Assignment.read/1`), the `input` (the execution's input
      bytes, which the assignment's `input_digest` binds; standard base64
      with padding on the wire, at most `max_input_bytes/0` decoded) and
      the `sealed_keys` (the attempt's keys sealed for this worker
      service, `Cyfr.WorkerAuth.seal_attempt_keys/3`). A runner takes one
      assignment at a time; the next `assign` follows its `complete`.
    * `cancel_child` — end the child `execution_id` of the runner's
      subtree: the runner kills the child's process and closes its
      attempt as abandoned. A cancel for a child the runner does not run
      is ignored. A subtree root is never cancelled here: the service
      ends the runner's process instead.

  Runner to service:

    * `complete` — the subtree the assignment named, whose root is
      `execution_id`, is closed: every attempt the runner ran has its
      terminal write with CYFR. `clean` is true when every component call
      returned on its own, so the runner may take another assignment for
      the same athanor; false when the runner killed a component call (a
      timeout, a lost lease, a cancel), whose native work may still be
      running, so the service ends the runner and never reuses it. The
      service knows the athanor from the assignment it read, so the frame
      does not repeat it.
    * `exit` — the runner's last frame before its process ends: the
      `runner` id it presented in its host calls (`t:runner_id/0`) and
      the attempts still `open` — attached or handed to it and not closed
      with CYFR, at most `max_open/0`. The service forwards it as
      `c:Cyfr.HostAPI.runner_exited/3`, so the list has that report's
      shape. A runner that ends without one left the service to report
      what it knows the runner held.

  ## Decoding

  `decode/1` answers the message or the first refusal, in this order:

    1. `:oversize_line` — the line is longer than `max_line_bytes/0`;
    2. `:malformed` — the line is not exactly one JSON object;
    3. `:bad_version` — `v` is absent or is not `1`;
    4. `:unknown_type` — `type` is absent or is not one of the four;
    5. `{:unknown_field, name}` — a member the message type does not
       carry (the first, by name);
    6. per field, in the order listed above: `{:missing_field, name}`;
       `{:wrong_type, name}` for a member of another JSON type;
       `{:invalid_field, name}` for one of the right type outside its
       shape (a string with a byte outside printable ASCII, an id longer
       than 256 bytes, text that is not base64, a list holding a
       non-id); `{:oversize, name}` for `input` above `max_input_bytes/0`
       or `open` longer than `max_open/0`.

  Identifiers (`execution_id`, `runner`, each of `open`) are 1 to 256
  bytes of printable ASCII without spaces, as every identifier on the
  worker protocol (`Cyfr.Assignment`, `Cyfr.MacEnvelope`). The
  assignment token and the sealed keys are printable ASCII without spaces
  of any length the line allows.
  """

  @version 1

  # The most input an assignment can carry: CYFR admits an input only up
  # to its node's `max_request_size`, which the platform ceiling bounds.
  @max_input_bytes Cyfr.Limits.Ceiling.lowered(%{}).max_request_size

  # A line holds the largest input in base64 with room to spare for the
  # assignment token and the sealed keys, whose own bounds keep them far
  # below the margin.
  @max_line_bytes 16 * 1024 * 1024

  # An `exit` forwarded as a `runner_exited` report must fit that report's
  # body (`Cyfr.HostAPI.max_body_bytes/0`): 1024 ids of at most 256 bytes,
  # quoted and separated, is about a quarter of it.
  @max_open 1024

  @id ~r/\A[\x21-\x7E]{1,256}\z/
  @text ~r/\A[\x21-\x7E]+\z/

  # Every message type, its wire name, who sends it and its fields in wire
  # order. The order is the encoding's and the decoder's refusal order.
  @messages [
    {:assign, "assign", :service, [assignment: :text, input: :bytes, sealed_keys: :text]},
    {:cancel_child, "cancel_child", :service, [execution_id: :id]},
    {:complete, "complete", :runner, [execution_id: :id, clean: :boolean]},
    {:exit, "exit", :runner, [runner: :id, open: :ids]}
  ]

  @by_type Map.new(@messages, fn {type, name, sender, fields} ->
             {type, {name, sender, fields}}
           end)
  @by_name Map.new(@messages, fn {type, name, _sender, fields} -> {name, {type, fields}} end)

  @typedoc """
  The id a runner presents as `runner` in its host-call headers
  (`t:Cyfr.WorkerAuth.host_call/0`): 1 to 256 bytes of printable ASCII
  without spaces.
  """
  @type runner_id :: String.t()

  @typedoc "Run a subtree: its signed assignment, its input bytes and its sealed attempt keys."
  @type assign :: %{
          type: :assign,
          assignment: Cyfr.Assignment.token(),
          input: binary(),
          sealed_keys: String.t()
        }

  @typedoc "End the child `execution_id` of the runner's subtree."
  @type cancel_child :: %{type: :cancel_child, execution_id: String.t()}

  @typedoc """
  The subtree rooted at `execution_id` is closed with CYFR; `clean` says
  every component call returned on its own, so the runner may be reused.
  """
  @type complete :: %{type: :complete, execution_id: String.t(), clean: boolean()}

  @typedoc "The runner ends, still holding the attempts in `open`."
  @type exit :: %{type: :exit, runner: runner_id(), open: [String.t()]}

  @type message :: assign() | cancel_child() | complete() | exit()

  @typedoc "A message type."
  @type type :: :assign | :cancel_child | :complete | :exit

  @typedoc "Which side sends a message."
  @type sender :: :service | :runner

  @typedoc "Why a line is not a frame (see the module's decoding order)."
  @type reason ::
          :oversize_line
          | :malformed
          | :bad_version
          | :unknown_type
          | {:unknown_field, String.t()}
          | {:missing_field, String.t()}
          | {:wrong_type, String.t()}
          | {:invalid_field, String.t()}
          | {:oversize, String.t()}

  @doc "The protocol version every frame carries as `v`."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The most bytes a frame's line may span, its newline excluded."
  @spec max_line_bytes() :: pos_integer()
  def max_line_bytes, do: @max_line_bytes

  @doc """
  The most input bytes an `assign` may carry, decoded: the platform
  ceiling on an execution's input (`Cyfr.Limits.Ceiling`), above which
  CYFR admits none.
  """
  @spec max_input_bytes() :: pos_integer()
  def max_input_bytes, do: @max_input_bytes

  @doc "The most attempts an `exit` may list as open."
  @spec max_open() :: pos_integer()
  def max_open, do: @max_open

  @doc "The message types, in the order the module documents them."
  @spec types() :: [type()]
  def types, do: Enum.map(@messages, fn {type, _name, _sender, _fields} -> type end)

  @doc "Which side sends a message of `type`: the service or the runner."
  @spec sender(type()) :: sender()
  def sender(type) when is_map_key(@by_type, type), do: @by_type |> Map.fetch!(type) |> elem(1)

  @doc """
  The line for `message`, as iodata ending in a newline. A message that is
  not one of the four, carries a member its type does not, lacks one, or
  holds a value `decode/1` would refuse raises `ArgumentError`, since it
  is the caller's own data.
  """
  @spec encode(message()) :: iodata()
  def encode(%{type: type} = message) when is_map_key(@by_type, type) do
    {name, _sender, fields} = Map.fetch!(@by_type, type)

    case Map.keys(message) -- [:type | Keyword.keys(fields)] do
      [] -> :ok
      [extra | _rest] -> raise ArgumentError, "#{type} carries no #{inspect(extra)}"
    end

    members =
      Enum.map(fields, fn {field, field_type} ->
        case Map.fetch(message, field) do
          {:ok, value} -> {field, write(field_type, field, value)}
          :error -> raise ArgumentError, "#{type} lacks #{inspect(field)}"
        end
      end)

    [Jason.encode_to_iodata!(Jason.OrderedObject.new([v: @version, type: name] ++ members)), ?\n]
  end

  def encode(message), do: raise(ArgumentError, "not a message: #{inspect(message)}")

  @doc """
  The message one line carries, with or without the newline that ends it,
  or the first reason it is not a frame (`t:reason/0`).
  """
  @spec decode(term()) :: {:ok, message()} | {:error, reason()}
  def decode(line) when is_binary(line) do
    line = trim_newline(line)

    with :ok <- within_line(line),
         {:ok, object} <- json_object(line),
         :ok <- known_version(object),
         {:ok, type, fields} <- known_type(object),
         :ok <- no_unknown_field(object, fields) do
      read_fields(type, fields, object)
    end
  end

  def decode(_line), do: {:error, :malformed}

  # ============================================================================
  # Reading
  # ============================================================================

  defp trim_newline(line)
       when byte_size(line) > 0 and binary_part(line, byte_size(line) - 1, 1) == "\n",
       do: binary_part(line, 0, byte_size(line) - 1)

  defp trim_newline(line), do: line

  defp within_line(line) when byte_size(line) <= @max_line_bytes, do: :ok
  defp within_line(_line), do: {:error, :oversize_line}

  defp json_object(line) do
    case Jason.decode(line) do
      {:ok, %{} = object} -> {:ok, object}
      _other -> {:error, :malformed}
    end
  end

  defp known_version(%{"v" => @version}), do: :ok
  defp known_version(_object), do: {:error, :bad_version}

  defp known_type(%{"type" => name}) when is_map_key(@by_name, name) do
    {type, fields} = Map.fetch!(@by_name, name)
    {:ok, type, fields}
  end

  defp known_type(_object), do: {:error, :unknown_type}

  defp no_unknown_field(object, fields) do
    known = ["v", "type" | Enum.map(fields, fn {field, _type} -> Atom.to_string(field) end)]

    case Enum.sort(Map.keys(object) -- known) do
      [] -> :ok
      [unknown | _rest] -> {:error, {:unknown_field, unknown}}
    end
  end

  defp read_fields(type, fields, object) do
    Enum.reduce_while(fields, {:ok, %{type: type}}, fn {field, field_type}, {:ok, message} ->
      name = Atom.to_string(field)

      case Map.fetch(object, name) do
        :error ->
          {:halt, {:error, {:missing_field, name}}}

        {:ok, value} ->
          case read(field_type, name, value) do
            {:ok, value} -> {:cont, {:ok, Map.put(message, field, value)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp read(:text, name, value) when is_binary(value), do: matching(@text, name, value)
  defp read(:id, name, value) when is_binary(value), do: matching(@id, name, value)

  defp read(:bytes, name, value) when is_binary(value) do
    # Base64 grows bytes by a third, so a text longer than the largest
    # input's is refused before it is decoded.
    with true <- byte_size(value) <= div(@max_input_bytes + 2, 3) * 4,
         {:ok, bytes} <- Base.decode64(value),
         true <- byte_size(bytes) <= @max_input_bytes do
      {:ok, bytes}
    else
      false -> {:error, {:oversize, name}}
      :error -> {:error, {:invalid_field, name}}
    end
  end

  defp read(:boolean, _name, value) when is_boolean(value), do: {:ok, value}

  defp read(:ids, name, value) when is_list(value) and length(value) > @max_open,
    do: {:error, {:oversize, name}}

  defp read(:ids, name, value) when is_list(value) do
    if Enum.all?(value, &(is_binary(&1) and Regex.match?(@id, &1))),
      do: {:ok, value},
      else: {:error, {:invalid_field, name}}
  end

  defp read(_type, name, _value), do: {:error, {:wrong_type, name}}

  defp matching(regex, name, value) do
    if Regex.match?(regex, value), do: {:ok, value}, else: {:error, {:invalid_field, name}}
  end

  # ============================================================================
  # Writing
  # ============================================================================

  # The wire value of a field, checked as `read/3` checks it back.
  defp write(:text, field, value) when is_binary(value) do
    if Regex.match?(@text, value), do: value, else: invalid(field)
  end

  defp write(:id, field, value) when is_binary(value) do
    if Regex.match?(@id, value), do: value, else: invalid(field)
  end

  defp write(:bytes, field, value) when is_binary(value) do
    if byte_size(value) <= @max_input_bytes, do: Base.encode64(value), else: invalid(field)
  end

  defp write(:boolean, _field, value) when is_boolean(value), do: value

  defp write(:ids, field, value) when is_list(value) do
    if length(value) <= @max_open and Enum.all?(value, &(is_binary(&1) and Regex.match?(@id, &1))),
      do: value,
      else: invalid(field)
  end

  defp write(_type, field, _value), do: invalid(field)

  defp invalid(field), do: raise(ArgumentError, "#{inspect(field)} is not of its type or bound")
end
