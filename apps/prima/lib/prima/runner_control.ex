# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.RunnerControl do
  @moduledoc """
  The local control channel between a worker service and one of its
  runners: the OS process that runs one execution subtree at a time. The
  service holds the channel's one end and the runner the other; the
  keeper that started the runner relays it over the runner's file
  descriptor 3. `tests/fixtures/runner_control.json` holds the vectors
  every encoder and decoder of it must reproduce.

  The service sends `assign` and `cancel_child`; the runner sends
  `child`, `complete`, `exit` and `event`. Guest data never travels on it: deltas,
  results, host-call bodies and vault fields go between the runner and
  CYFR over the host API (`Prima.HostAPI`), under the attempt's keys. What crosses
  here is what `c:Prima.WorkerAPI.start/3` was given, its sealed keys
  opened, and what the service reports (`c:Prima.HostAPI.runner_exited/5`).
  The channel carries no MAC: the keeper's process isolation is its
  boundary, and nothing on it authorizes anything — CYFR verifies the
  assignment when the runner attaches, and an attempt's keys sign and
  open for that attempt on this worker service only.

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
      `t:Prima.Assignment.token/0`, opaque here and read by the runner
      with `Prima.Assignment.read/1`), the `input` (the execution's input
      bytes, which the assignment's `input_digest` binds; standard base64
      with padding on the wire, at most `max_input_bytes/0` decoded) and
      the `keys`: the attempt's keys as the service opened them
      (`Prima.WorkerAuth.open_attempt_keys/2`), an object of the `attempt`
      they are bound to (its six fields, `t:Prima.WorkerAuth.attempt/0`)
      and the `call` and `seal` keys, each 32 bytes as 64 lowercase hex
      digits. The service opens them because the dispatch seal key never
      leaves the service: a runner holding it could open the keys of
      every attempt sealed for this worker service. A runner takes one
      assignment at a time; the next `assign` follows its `complete`.
    * `cancel_child` — end the child `execution_id` of the runner's
      subtree: the runner kills the child's process and closes its
      attempt as abandoned. A cancel for a child the runner does not run
      is ignored. A subtree root is never cancelled here: the service
      ends the runner's process instead.

  Runner to service:

    * `child` — the runner started the child `execution_id` of its
      subtree, whose attempt is `attempt`, in a process of its own: a
      formula's guest asked for it and CYFR admitted it for this runner.
      It is how the service knows which runner holds a child, so that a
      kill of it reaches that runner (`c:Prima.WorkerAPI.kill/1`) and a
      runner that ends without an `exit` is reported holding it.
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
      `c:Prima.HostAPI.runner_exited/5`, so the list has that report's
      shape. A runner that ends without one left the service to report
      what it knows the runner held.
    * `event` — one operator event the runner observed, for the service
      to forward to CYFR, which emits it as
      `[:cyfr, :locus, :runtime | name]`: its `name`, the event's suffix
      joined with dots (`http.request`), and its `measurements` and
      `metadata`, each an object of exactly the members `event_roster/0`
      gives that name, in its order. A measurement is an integer, 0 to
      2^53 − 1; a metadata string is UTF-8 of at most
      `max_event_string_bytes/0` bytes; a status word is a string. An
      `event` line spans at most `max_event_line_bytes/0` bytes before its
      newline. The runner is untrusted, so an event off the roster is not
      a frame.

  ## Decoding

  `decode/1` answers the message or the first refusal, in this order:

    1. `:oversize_line` — the line is longer than `max_line_bytes/0`;
    2. `:malformed` — the line is not exactly one JSON object;
    3. `:bad_version` — `v` is absent or is not `1`;
    4. `:unknown_type` — `type` is absent or is not one of the six;
       then, for an `event`, `:oversize_line` when the line is longer
       than `max_event_line_bytes/0`;
    5. `{:unknown_field, name}` — a member the message type does not
       carry (the first, by name);
    6. per field, in the order listed above: `{:missing_field, name}`;
       `{:wrong_type, name}` for a member of another JSON type;
       `{:invalid_field, name}` for one of the right type outside its
       shape (a string with a byte outside printable ASCII, an id longer
       than 256 bytes, text that is not base64, a key that is not 64
       lowercase hex digits, an integer outside 0 to 2^53 − 1, a list
       holding a non-id, an event `name` off the roster, a status word
       outside its set, an HTTP status outside 100 to 599);
       `{:oversize, name}` for `input` above `max_input_bytes/0`, `open`
       longer than `max_open/0` or a metadata string longer than
       `max_event_string_bytes/0`.

  An object member is checked the same way, once its object is reached:
  its unknown members first, then each of its members in order. It is
  named by its path, `keys.call`, `keys.attempt.fence` or
  `metadata.status`. An event's `measurements` and `metadata` are read
  by the roster's entry for the `name` read before them.

  Identifiers (`execution_id`, `attempt`, `runner`, each of `open`, the
  strings of `keys.attempt`) are 1 to 256 bytes of printable ASCII
  without spaces, as every identifier on the worker protocol
  (`Prima.Assignment`, `Prima.MacEnvelope`), and the integers of `keys.attempt` are 0 to
  2^53 − 1, as `Prima.MacEnvelope` reads an integer field. The assignment
  token is printable ASCII without spaces of any length the line allows.

  ## Writing an event

  `encode/1` cuts each metadata string longer than
  `max_event_string_bytes/0` to its first that many bytes, backed off to
  a character boundary so no UTF-8 sequence is split, so an event with a
  long tool or action name still goes. Cutting bounds the bytes a string
  holds, not the bytes JSON escapes it to: an event whose line is still
  longer than `max_event_line_bytes/0` after cutting (strings full of
  characters JSON escapes) is not a frame, and `encode/1` raises
  `ArgumentError` for it as for any other message `decode/1` would
  refuse, so the sender drops that event.
  """

  @version 1

  # The most input an assignment can carry: CYFR admits an input only up
  # to its node's `max_request_size`, which the platform ceiling bounds.
  @max_input_bytes Prima.Limits.Ceiling.lowered(%{}).max_request_size

  # A line holds the largest input in base64 with room to spare for the
  # assignment token and the keys, whose own bounds keep them far below
  # the margin.
  @max_line_bytes 16 * 1024 * 1024

  # An `exit` forwarded as a `runner_exited` report must fit that report's
  # body (`Prima.HostAPI.max_body_bytes/0`): 1024 ids of at most 256 bytes,
  # quoted and separated, is about a quarter of it.
  @max_open 1024

  # 2^53 − 1: `Prima.MacEnvelope`'s integer field domain.
  @max_integer 9_007_199_254_740_991

  # An event is one small frame: its strings are cut to a bound and its
  # line is held to a page, so a runner's events never crowd its other
  # frames.
  @max_event_line_bytes 4096
  @max_event_string_bytes 256

  # The operator events a runner sends, by name: each one's measurements
  # and metadata, every member with its type, in wire order. The
  # measurements are integers. `system_time` is microseconds since the
  # epoch on the wire, since nanoseconds since the epoch pass 2^53 − 1,
  # the channel's integer domain; the core emits it in its own unit,
  # nanoseconds, multiplying it by 1,000.
  # A status word is a string here and the core's atom there; an HTTP
  # status stays an integer.
  @events [
    {"engine.authority_entered", [], [execution_id: :string, reference: :string]},
    {"http.request", [duration_ms: :integer, system_time: :integer],
     [
       component_ref: :string,
       method: :string,
       hostname: :string,
       status: {:one_of, ~w(response_too_large timeout error), :http_status}
     ]},
    {"storage.call", [duration_ms: :integer],
     [component_ref: :string, action: :string, status: {:one_of, ~w(ok error)}]},
    {"mcp_tool.call", [duration_ms: :integer],
     [execution_id: :string, tool_action: :string, status: {:one_of, ~w(ok error)}]},
    {"formula.spawn", [system_time: :integer],
     [parent_execution_id: :string, task_id: :string, component_ref: :string]},
    {"formula.await", [duration_ms: :integer],
     [task_id: :string, status: {:one_of, ~w(completed timeout error)}]},
    {"formula.await_all", [duration_ms: :integer],
     [parent_execution_id: :string, count: :integer, timed_out: :integer]},
    {"formula.cancel", [system_time: :integer], [parent_execution_id: :string, task_id: :string]},
    {"formula.await_any", [duration_ms: :integer],
     [parent_execution_id: :string, winner_task_id: :string_or_null]}
  ]

  @events_by_name Map.new(@events, fn {name, measurements, metadata} ->
                    {name, %{measurements: measurements, metadata: metadata}}
                  end)

  @id ~r/\A[\x21-\x7E]{1,256}\z/
  @text ~r/\A[\x21-\x7E]+\z/
  @hex_key ~r/\A[0-9a-f]{64}\z/

  # The attempt an attempt's keys are bound to, in `Prima.WorkerAuth`'s
  # field order, and the opened keys themselves.
  @attempt_fields [
    athanor_id: :id,
    execution_id: :id,
    attempt: :id,
    fence: :integer,
    generation: :integer,
    service: :id
  ]
  @keys_fields [attempt: {:object, @attempt_fields}, call: :key, seal: :key]

  # Every message type, its wire name, who sends it and its fields in wire
  # order. The order is the encoding's and the decoder's refusal order.
  @messages [
    {:assign, "assign", :service,
     [assignment: :text, input: :bytes, keys: {:object, @keys_fields}]},
    {:cancel_child, "cancel_child", :service, [execution_id: :id]},
    {:child, "child", :runner, [execution_id: :id, attempt: :id]},
    {:complete, "complete", :runner, [execution_id: :id, clean: :boolean]},
    {:exit, "exit", :runner, [runner: :id, open: :ids]},
    {:event, "event", :runner,
     [name: :event_name, measurements: {:event, :measurements}, metadata: {:event, :metadata}]}
  ]

  @by_type Map.new(@messages, fn {type, name, sender, fields} ->
             {type, {name, sender, fields}}
           end)
  @by_name Map.new(@messages, fn {type, name, _sender, fields} -> {name, {type, fields}} end)

  @typedoc """
  The id a runner presents as `runner` in its host-call headers
  (`t:Prima.WorkerAuth.host_call/0`): 1 to 256 bytes of printable ASCII
  without spaces.
  """
  @type runner_id :: String.t()

  @typedoc "Run a subtree: its signed assignment, its input bytes and its attempt's opened keys."
  @type assign :: %{
          type: :assign,
          assignment: Prima.Assignment.token(),
          input: binary(),
          keys: Prima.WorkerAuth.attempt_keys()
        }

  @typedoc "End the child `execution_id` of the runner's subtree."
  @type cancel_child :: %{type: :cancel_child, execution_id: String.t()}

  @typedoc "The runner started the child `execution_id` of its subtree, whose attempt is `attempt`."
  @type child :: %{type: :child, execution_id: String.t(), attempt: String.t()}

  @typedoc """
  The subtree rooted at `execution_id` is closed with CYFR; `clean` says
  every component call returned on its own, so the runner may be reused.
  """
  @type complete :: %{type: :complete, execution_id: String.t(), clean: boolean()}

  @typedoc "The runner ends, still holding the attempts in `open`."
  @type exit :: %{type: :exit, runner: runner_id(), open: [String.t()]}

  @typedoc """
  One operator event: its `name` on the roster (`event_roster/0`), and
  its `measurements` and `metadata` with exactly that entry's members.
  """
  @type event :: %{
          type: :event,
          name: String.t(),
          measurements: %{optional(atom()) => non_neg_integer()},
          metadata: %{optional(atom()) => String.t() | non_neg_integer() | nil}
        }

  @type message :: assign() | cancel_child() | child() | complete() | exit() | event()

  @typedoc "A message type."
  @type type :: :assign | :cancel_child | :child | :complete | :exit | :event

  @typedoc """
  The type of one member of an event's measurements or metadata: an
  integer, 0 to 2^53 − 1; a string; a string or null; a status word of a
  set; or, for an HTTP request's status, one of a set or an HTTP status
  (100 to 599).
  """
  @type event_member ::
          :integer
          | :string
          | :string_or_null
          | {:one_of, [String.t()]}
          | {:one_of, [String.t()], :http_status}

  @typedoc "One roster entry: an event's name and its members in wire order."
  @type event_entry :: %{
          name: String.t(),
          measurements: [{atom(), event_member()}],
          metadata: [{atom(), event_member()}]
        }

  @typedoc "Which side sends a message."
  @type sender :: :service | :runner

  @typedoc """
  Why a line is not a frame (see the module's decoding order). A name is
  a member's path: `clean`, `keys.call`, `keys.attempt.fence`.
  """
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
  ceiling on an execution's input (`Prima.Limits.Ceiling`), above which
  CYFR admits none.
  """
  @spec max_input_bytes() :: pos_integer()
  def max_input_bytes, do: @max_input_bytes

  @doc "The most attempts an `exit` may list as open."
  @spec max_open() :: pos_integer()
  def max_open, do: @max_open

  @doc "The most bytes an `event` frame's line may span, its newline excluded."
  @spec max_event_line_bytes() :: pos_integer()
  def max_event_line_bytes, do: @max_event_line_bytes

  @doc "The most bytes a metadata string of an `event` may hold."
  @spec max_event_string_bytes() :: pos_integer()
  def max_event_string_bytes, do: @max_event_string_bytes

  @doc """
  The operator events a runner may send, in the order the catalog lists
  them: each one's name and its measurements' and metadata's members,
  each with its type (`t:event_member/0`), in wire order.
  """
  @spec event_roster() :: [event_entry()]
  def event_roster do
    Enum.map(@events, fn {name, measurements, metadata} ->
      %{name: name, measurements: measurements, metadata: metadata}
    end)
  end

  @doc """
  The grammar of an athanor's id on every Locus wire: this channel's
  `keys.attempt.athanor_id`, a build request's `athanor_id`
  (`Prima.BuilderProtocol`) and a place's `athanor` (`Prima.KeeperProtocol`),
  1 to 256 bytes of printable ASCII without spaces, as every identifier of
  this channel.
  """
  @spec athanor_id_pattern() :: Regex.t()
  def athanor_id_pattern, do: @id

  @doc "The message types, in the order the module documents them."
  @spec types() :: [type()]
  def types, do: Enum.map(@messages, fn {type, _name, _sender, _fields} -> type end)

  @doc "Which side sends a message of `type`: the service or the runner."
  @spec sender(type()) :: sender()
  def sender(type) when is_map_key(@by_type, type), do: @by_type |> Map.fetch!(type) |> elem(1)

  @doc """
  The line for `message`, as iodata ending in a newline. A message that is
  not one of the six, carries a member its type does not, lacks one, or
  holds a value `decode/1` would refuse raises `ArgumentError`, since it
  is the caller's own data. An event's metadata strings are cut first
  (see the module's writing an event).
  """
  @spec encode(message()) :: iolist()
  def encode(%{type: type} = message) when is_map_key(@by_type, type) do
    {name, _sender, fields} = Map.fetch!(@by_type, type)
    %Jason.OrderedObject{values: members} = write_object(fields, Map.delete(message, :type), "")
    object = Jason.OrderedObject.new([v: @version, type: name] ++ members)
    line = Jason.encode_to_iodata!(object)

    if type == :event and IO.iodata_length(line) > @max_event_line_bytes,
      do: raise(ArgumentError, "the event's line is past #{@max_event_line_bytes} bytes")

    [line, ?\n]
  end

  def encode(message),
    do: raise(ArgumentError, "not a message: #{Prima.LoggerContext.shape(message)}")

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
         :ok <- within_type_line(type, line),
         {:ok, message} <- read_object(fields, Map.drop(object, ["v", "type"]), "") do
      {:ok, Map.put(message, :type, type)}
    end
  end

  def decode(_line), do: {:error, :malformed}

  @doc """
  An `event` as one record of a `report_events` batch
  (`Prima.HostAPI.report_events_args/1`): the frame's `name`,
  `measurements` and `metadata`, each checked and its strings cut to
  their bound as `encode/1` writes them, as a JSON object of string keys,
  as every host call's args are. Raises as `encode/1` does.
  """
  @spec event_record(event()) :: %{String.t() => term()}
  def event_record(%{type: :event} = event) do
    {_name, _sender, fields} = Map.fetch!(@by_type, :event)
    fields |> write_object(Map.delete(event, :type), "") |> plain()
  end

  defp plain(%Jason.OrderedObject{values: members}),
    do: Map.new(members, fn {key, value} -> {Atom.to_string(key), plain(value)} end)

  defp plain(value), do: value

  @doc """
  The `event` one record of a `report_events` batch carries, read by the
  roster as `decode/1` reads an `event` frame's members, or the first
  reason it is not one.
  """
  @spec read_event(term()) :: {:ok, event()} | {:error, reason()}
  def read_event(%{} = record) when not is_struct(record) do
    {_name, _sender, fields} = Map.fetch!(@by_type, :event)

    with {:ok, event} <- read_object(fields, record, ""),
         do: {:ok, Map.put(event, :type, :event)}
  end

  def read_event(_record), do: {:error, :malformed}

  # ============================================================================
  # Reading
  # ============================================================================

  defp trim_newline(line)
       when byte_size(line) > 0 and binary_part(line, byte_size(line) - 1, 1) == "\n",
       do: binary_part(line, 0, byte_size(line) - 1)

  defp trim_newline(line), do: line

  defp within_line(line) when byte_size(line) <= @max_line_bytes, do: :ok
  defp within_line(_line), do: {:error, :oversize_line}

  defp within_type_line(:event, line) when byte_size(line) > @max_event_line_bytes,
    do: {:error, :oversize_line}

  defp within_type_line(_type, _line), do: :ok

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

  # An object's members as `fields` declares them: no other member, and
  # each present and of its type, in order. `path` prefixes each member's
  # name in a refusal. A member whose type is the roster's is read by the
  # entry of the event name read before it.
  defp read_object(fields, object, path) do
    with :ok <- no_unknown_field(fields, object, path) do
      Enum.reduce_while(fields, {:ok, %{}}, fn {field, field_type}, {:ok, read} ->
        name = path <> Atom.to_string(field)

        with {:ok, value} <- member(object, field, name),
             {:ok, value} <- read(roster_type(field_type, read), name, value) do
          {:cont, {:ok, Map.put(read, field, value)}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp no_unknown_field(fields, object, path) do
    known = Enum.map(fields, fn {field, _type} -> Atom.to_string(field) end)

    case Enum.sort(Map.keys(object) -- known) do
      [] -> :ok
      [unknown | _rest] -> {:error, {:unknown_field, path <> unknown}}
    end
  end

  # The object an event's `measurements` or `metadata` is, by the roster's
  # entry for its `name`, which is read first and is on the roster.
  defp roster_type({:event, part}, %{name: name}),
    do: {:object, @events_by_name |> Map.fetch!(name) |> Map.fetch!(part)}

  defp roster_type(field_type, _read), do: field_type

  defp member(object, field, name) do
    case Map.fetch(object, Atom.to_string(field)) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_field, name}}
    end
  end

  defp read({:object, fields}, name, %{} = value), do: read_object(fields, value, name <> ".")
  defp read(:text, name, value) when is_binary(value), do: matching(@text, name, value)
  defp read(:id, name, value) when is_binary(value), do: matching(@id, name, value)

  defp read(:key, name, value) when is_binary(value) do
    if Regex.match?(@hex_key, value),
      do: {:ok, Base.decode16!(value, case: :lower)},
      else: {:error, {:invalid_field, name}}
  end

  defp read(:integer, _name, value)
       when is_integer(value) and value >= 0 and value <= @max_integer,
       do: {:ok, value}

  defp read(:integer, name, value) when is_integer(value), do: {:error, {:invalid_field, name}}

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

  defp read(:event_name, _name, value) when is_map_key(@events_by_name, value), do: {:ok, value}
  defp read(:event_name, name, value) when is_binary(value), do: {:error, {:invalid_field, name}}

  defp read(type, name, value)
       when type in [:string, :string_or_null] and is_binary(value) and
              byte_size(value) > @max_event_string_bytes,
       do: {:error, {:oversize, name}}

  defp read(type, _name, value) when type in [:string, :string_or_null] and is_binary(value),
    do: {:ok, value}

  defp read(:string_or_null, _name, nil), do: {:ok, nil}

  defp read({:one_of, _words, :http_status}, _name, value)
       when is_integer(value) and value in 100..599,
       do: {:ok, value}

  defp read({:one_of, _words, :http_status}, name, value) when is_integer(value),
    do: {:error, {:invalid_field, name}}

  defp read({:one_of, words, _http_status}, name, value) when is_binary(value),
    do: read({:one_of, words}, name, value)

  defp read({:one_of, words}, name, value) when is_binary(value) do
    if value in words, do: {:ok, value}, else: {:error, {:invalid_field, name}}
  end

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

  # An object's members in `fields`' order, each checked as `read/3`
  # checks it back; a member the object lacks or does not declare raises.
  # An event's name is written, and so checked, before the members the
  # roster gives it.
  defp write_object(fields, map, path) when is_map(map) and not is_struct(map) do
    case Map.keys(map) -- Keyword.keys(fields) do
      [] -> :ok
      [extra | _rest] -> raise ArgumentError, "#{path}#{extra} is not a member"
    end

    fields
    |> Enum.map(fn {field, field_type} ->
      name = path <> Atom.to_string(field)

      case Map.fetch(map, field) do
        {:ok, value} -> {field, write(roster_type(field_type, map), name, value)}
        :error -> raise ArgumentError, "#{name} is missing"
      end
    end)
    |> Jason.OrderedObject.new()
  end

  defp write_object(_fields, _map, path), do: invalid(String.trim_trailing(path, "."))

  defp write({:object, fields}, name, value), do: write_object(fields, value, name <> ".")

  defp write(:text, name, value) when is_binary(value) do
    if Regex.match?(@text, value), do: value, else: invalid(name)
  end

  defp write(:id, name, value) when is_binary(value) do
    if Regex.match?(@id, value), do: value, else: invalid(name)
  end

  defp write(:key, _name, value) when is_binary(value) and byte_size(value) == 32,
    do: Base.encode16(value, case: :lower)

  defp write(:integer, _name, value)
       when is_integer(value) and value >= 0 and value <= @max_integer,
       do: value

  defp write(:bytes, name, value) when is_binary(value) do
    if byte_size(value) <= @max_input_bytes, do: Base.encode64(value), else: invalid(name)
  end

  defp write(:boolean, _name, value) when is_boolean(value), do: value

  defp write(:event_name, _name, value) when is_map_key(@events_by_name, value), do: value

  defp write(type, name, value) when type in [:string, :string_or_null] and is_binary(value) do
    if String.valid?(value), do: cut(value), else: invalid(name)
  end

  defp write(:string_or_null, _name, nil), do: nil

  defp write({:one_of, _words, :http_status}, _name, value)
       when is_integer(value) and value in 100..599,
       do: value

  defp write({:one_of, words, _http_status}, name, value) when is_binary(value),
    do: write({:one_of, words}, name, value)

  defp write({:one_of, words}, name, value) when is_binary(value) do
    if value in words, do: value, else: invalid(name)
  end

  defp write(:ids, name, value) when is_list(value) do
    if length(value) <= @max_open and Enum.all?(value, &(is_binary(&1) and Regex.match?(@id, &1))),
      do: value,
      else: invalid(name)
  end

  defp write(_type, name, _value), do: invalid(name)

  # A metadata string cut to the bound: its first bytes up to it, then
  # back to the last character boundary, so the cut never splits a UTF-8
  # sequence of the valid string it was taken from.
  defp cut(value) when byte_size(value) <= @max_event_string_bytes, do: value
  defp cut(value), do: boundary(binary_part(value, 0, @max_event_string_bytes))

  defp boundary(prefix) do
    if String.valid?(prefix),
      do: prefix,
      else: boundary(binary_part(prefix, 0, byte_size(prefix) - 1))
  end

  @spec invalid(String.t()) :: no_return()
  defp invalid(name), do: raise(ArgumentError, "#{name} is not of its type or bound")
end
