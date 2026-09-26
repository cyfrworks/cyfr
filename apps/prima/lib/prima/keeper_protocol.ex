# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.KeeperProtocol do
  @moduledoc """
  The wire between `cyfr-keeper` (`apps/keeper`) and its clients,
  `Opus.Keeper.Channel` and `Locus.Keeper`: the request and reply lines on
  the inherited channel (fd 3) and the frames on a spawn's attach
  connection. `tests/fixtures/keeper_protocol.json` holds the vectors the
  keeper and every client reproduce. Pure: the attach token's entropy is
  the client's.

  ## Lines

  A request or a reply is one JSON object on one line, ending in `\\n`,
  carrying `"v": 1` and a `type`, at most `max_line_bytes/0` bytes before
  its newline. A client sends `spawn`, `signal`, `release` and `pool`; the
  keeper answers `spawned`, `error`, `exited`, `released` and `pool`.

  `encode/1` writes a request's members in name order, `v` and `type`
  among them, and refuses by raising `ArgumentError` what the keeper
  refuses as `bad_request`: a member the type does not carry, a required
  one absent, and a value outside its bound, as the keeper's
  `ParseRequest` reads them. A refusal names the member at fault by its
  path (`argv`, `attach.token`, `rlimits.nofile`) and never quotes a
  value, since an environment value may be a credential.

  `decode_reply/1` answers the reply or the first refusal, in this order:
  `:oversize_line`; `:malformed` (not one JSON object); `:bad_version`;
  `:unknown_type`; `{:unknown_field, name}` (the first by name); then per
  member, in the order the type lists them, `{:missing_field, name}`,
  `{:wrong_type, name}` or `{:invalid_field, name}`; and last, for an
  `exited`, `:ambiguous_exit` when it carries both a `code` and a
  `signal`, or neither.

  ## Frames

  A frame is a stream byte (`streams/0`), a 4-byte big-endian length and
  at most `max_frame_bytes/0` bytes of payload; a zero-length frame ends
  its stream. A relay's first frame is the attach frame, stream 3, whose
  payload is the spawn's token of `token_hex_bytes/0` lowercase hex
  digits. Which streams a client accepts past the attach frame is the
  client's own: a stream it never asked for is a relay fault there.
  """

  @version 1
  @max_frame_bytes 65_536
  @max_line_bytes 1_048_576
  @token_hex_bytes 64

  @streams [stdin: 0, stdout: 1, stderr: 2, attach: 3, control: 4]
  @stream_byte Map.new(@streams)
  @stream_name Map.new(@streams, fn {name, byte} -> {byte, name} end)
  @attach_stream Keyword.fetch!(@streams, :attach)

  # The keeper's request bounds (`apps/keeper/internal/protocol`).
  @max_args 256
  @max_env 256
  @max_value_bytes 32 * 1024
  @max_spec_bytes 256 * 1024
  @max_grace_ms 60_000
  @max_socket_path 107
  @min_memory_bytes 16 * 1024 * 1024
  @max_memory_bytes 1024 * 1024 * 1024 * 1024
  @signals ~w(SIGTERM SIGKILL SIGINT SIGHUP SIGQUIT SIGUSR1 SIGUSR2)
  @reserved_env ~w(PATH HOME USER LOGNAME SHELL TMPDIR PWD)
  @reserved_env_prefixes ~w(CYFR_ LOCUS_ KEEPER_)
  # Each limit's least and most, the most being the keeper's ceiling.
  @rlimits [
    core: {0, 0},
    fsize: {1, 256 * 1024 * 1024},
    nofile: {16, 1024},
    nproc: {1, 128}
  ]

  # The integers a reply carries: uids, pids and pool counts.
  @max_count 4_294_967_295

  @id ~r/\A[A-Za-z0-9._:-]{1,64}\z/
  @pool ~r/\A[a-z][a-z0-9-]{0,31}\z/
  @spawn_id ~r/\A[0-9a-f]{32}\z/
  @token ~r/\A[0-9a-f]{64}\z/
  @env_name ~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/
  @code ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @signal ~r/\A[\x20-\x7E]{1,64}\z/

  # Every request type, its wire name and its members: required or not.
  @requests %{
    spawn:
      {"spawn",
       [
         id: :required,
         pool: :required,
         argv: :required,
         env: :optional,
         rlimits: :optional,
         memory_bytes: :optional,
         control: :optional,
         attach: :required
       ]},
    signal: {"signal", [spawn_id: :required, sig: :required]},
    release: {"release", [spawn_id: :required, grace_ms: :required]},
    pool: {"pool", [id: :required, pool: :required]}
  }

  # Every reply type and its members in the order they are read.
  @replies %{
    "spawned" => {:spawned, [id: :id, spawn_id: :spawn_id, uid: :count, pid: :count]},
    "error" => {:error, [id: {:nullable, :id}, spawn_id: {:nullable, :spawn_id}, code: :code]},
    "exited" =>
      {:exited,
       [
         spawn_id: :spawn_id,
         code: {:nullable, :integer},
         signal: {:nullable, :signal},
         memory_exceeded: :boolean
       ]},
    "released" => {:released, [spawn_id: :spawn_id]},
    "pool" => {:pool, [id: :id, pool: :pool, size: :count, free: :count, quarantined: :count]}
  }

  # An `error` names its request by `id` or `spawn_id`, and a request the
  # keeper could not read by neither.
  @optional_reply_members %{error: [:id, :spawn_id]}

  @typedoc "A stream of an attach connection."
  @type stream :: :stdin | :stdout | :stderr | :attach | :control

  @typedoc "A signal a `signal` request may name."
  @type signal :: String.t()

  @typedoc """
  A request, as `encode/1` takes it: its `type` and its members, with atom
  keys but for `env`'s names. `spawn` requires `id`, `pool`, `argv` and
  `attach` (`%{path: path, token: token}`); `env` (names to values),
  `rlimits` (`nofile`, `nproc`, `core`, `fsize`), `memory_bytes` and
  `control` are optional.
  """
  @type request ::
          %{
            required(:type) => :spawn,
            required(:id) => String.t(),
            required(:pool) => String.t(),
            required(:argv) => [String.t(), ...],
            optional(:env) => %{optional(String.t()) => String.t()},
            optional(:rlimits) => %{optional(atom()) => non_neg_integer()},
            optional(:memory_bytes) => pos_integer(),
            optional(:control) => boolean(),
            required(:attach) => %{path: String.t(), token: String.t()}
          }
          | %{type: :signal, spawn_id: String.t(), sig: signal()}
          | %{type: :release, spawn_id: String.t(), grace_ms: non_neg_integer()}
          | %{type: :pool, id: String.t(), pool: String.t()}

  @typedoc "How a spawn's leader ended: its exit status or the signal that ended it."
  @type exit_status :: {:status, integer()} | {:signal, String.t()}

  @typedoc """
  A reply. An `error` names the request it refuses by `id` (a spawn or a
  pool request) or `spawn_id` (a signal or a release); a request the
  keeper could not read is named by neither.
  """
  @type reply ::
          {:spawned, id :: String.t(), spawn_id :: String.t(), uid :: non_neg_integer(),
           pid :: non_neg_integer()}
          | {:error, id :: String.t() | nil, spawn_id :: String.t() | nil, code :: String.t()}
          | {:exited, spawn_id :: String.t(), exit_status(), memory_exceeded :: boolean()}
          | {:released, spawn_id :: String.t()}
          | {:pool, id :: String.t(), pool :: String.t(), size :: non_neg_integer(),
             free :: non_neg_integer(), quarantined :: non_neg_integer()}

  @typedoc "Why a line is not a reply (see the module's decoding order)."
  @type reason ::
          :oversize_line
          | :malformed
          | :bad_version
          | :unknown_type
          | {:unknown_field, String.t()}
          | {:missing_field, String.t()}
          | {:wrong_type, String.t()}
          | {:invalid_field, String.t()}
          | :ambiguous_exit

  @doc "The protocol version every line carries as `v`."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The most payload bytes a frame carries."
  @spec max_frame_bytes() :: pos_integer()
  def max_frame_bytes, do: @max_frame_bytes

  @doc "The most bytes a line may span, its newline excluded."
  @spec max_line_bytes() :: pos_integer()
  def max_line_bytes, do: @max_line_bytes

  @doc "The length of a spawn's attach token: lowercase hex digits."
  @spec token_hex_bytes() :: pos_integer()
  def token_hex_bytes, do: @token_hex_bytes

  @doc "The streams of an attach connection and their bytes, in byte order."
  @spec streams() :: [{stream(), 0..4}]
  def streams, do: @streams

  @doc "The variable names no spawn's `env` may carry."
  @spec reserved_env_names() :: [String.t()]
  def reserved_env_names, do: @reserved_env

  @doc "The variable name prefixes no spawn's `env` may carry."
  @spec reserved_env_prefixes() :: [String.t()]
  def reserved_env_prefixes, do: @reserved_env_prefixes

  # ============================================================================
  # Frames
  # ============================================================================

  @doc """
  One frame of `payload` on `stream`, as iodata. A payload above
  `max_frame_bytes/0` or a stream that is not one raises `ArgumentError`.
  """
  @spec frame(stream(), binary()) :: iolist()
  def frame(stream, payload)
      when is_map_key(@stream_byte, stream) and is_binary(payload) and
             byte_size(payload) <= @max_frame_bytes,
      do: [<<Map.fetch!(@stream_byte, stream), byte_size(payload)::32>>, payload]

  def frame(_stream, _payload),
    do: raise(ArgumentError, "a frame is a stream and at most #{@max_frame_bytes} bytes")

  @doc """
  `data` on `stream` as frames of at most `max_frame_bytes/0` each, none
  for no data. The stream's end is `end_frame/1`'s, sent apart.
  """
  @spec frames(stream(), binary()) :: [iolist()]
  def frames(stream, <<chunk::binary-size(@max_frame_bytes), rest::binary>>),
    do: [frame(stream, chunk) | frames(stream, rest)]

  def frames(stream, <<>>) when is_map_key(@stream_byte, stream), do: []
  def frames(stream, data) when is_binary(data), do: [frame(stream, data)]

  @doc "The zero-length frame that ends `stream`."
  @spec end_frame(stream()) :: iolist()
  def end_frame(stream), do: frame(stream, "")

  @doc """
  The complete frames at the head of `buffer`, in order, and the bytes
  after them, which wait for more. A header announcing more than
  `max_frame_bytes/0` is `:oversized` and a stream byte outside
  `streams/0` is `:unknown_stream`, each as soon as its header is in: a
  relay that sends either is at fault, and nothing it sent is trusted.
  """
  @spec parse_frames(binary()) ::
          {:ok, [{stream(), binary()}], binary()} | {:error, :oversized | :unknown_stream}
  def parse_frames(buffer) when is_binary(buffer), do: parse_frames(buffer, [])

  defp parse_frames(<<_stream, length::32, _rest::binary>>, _frames)
       when length > @max_frame_bytes,
       do: {:error, :oversized}

  defp parse_frames(<<stream, _length::32, _rest::binary>>, _frames)
       when not is_map_key(@stream_name, stream),
       do: {:error, :unknown_stream}

  defp parse_frames(<<stream, length::32, payload::binary-size(length), rest::binary>>, frames),
    do: parse_frames(rest, [{Map.fetch!(@stream_name, stream), payload} | frames])

  defp parse_frames(rest, frames), do: {:ok, Enum.reverse(frames), rest}

  @doc """
  The attach frame presenting `token`. A token that is not
  `token_hex_bytes/0` lowercase hex digits raises `ArgumentError`.
  """
  @spec attach_frame(String.t()) :: iolist()
  def attach_frame(token) when is_binary(token) do
    if Regex.match?(@token, token),
      do: frame(:attach, token),
      else: raise(ArgumentError, "attach.token is not #{@token_hex_bytes} lowercase hex digits")
  end

  @doc """
  The token an attach frame presents: `bytes` is the frame whole, its
  header and its `token_hex_bytes/0` of payload. Anything else, a token
  of another length or with a byte that is not a lowercase hex digit
  among them, is `:malformed`.
  """
  @spec decode_attach(binary()) :: {:ok, String.t()} | {:error, :malformed}
  def decode_attach(
        <<@attach_stream, @token_hex_bytes::32, token::binary-size(@token_hex_bytes)>>
      ) do
    if Regex.match?(@token, token), do: {:ok, token}, else: {:error, :malformed}
  end

  def decode_attach(_bytes), do: {:error, :malformed}

  # ============================================================================
  # Lines
  # ============================================================================

  @doc """
  The complete lines of `buffer` followed by `data`, without their
  newlines, and the partial line after them. A line longer than
  `max_line_bytes/0`, complete or not, is `:line_too_long`: the channel
  is at fault.
  """
  @spec split_lines(binary(), binary()) :: {[binary()], binary()} | {:error, :line_too_long}
  def split_lines(buffer, data) when is_binary(buffer) and is_binary(data) do
    {lines, [rest]} = (buffer <> data) |> :binary.split("\n", [:global]) |> Enum.split(-1)

    if Enum.all?([rest | lines], &(byte_size(&1) <= @max_line_bytes)),
      do: {lines, rest},
      else: {:error, :line_too_long}
  end

  @doc """
  The line for `request` (`t:request/0`), as iodata ending in a newline.
  A request the keeper would refuse as `bad_request` raises
  `ArgumentError` naming the member at fault, since it is the caller's
  own data.
  """
  @spec encode(request()) :: iolist()
  def encode(%{type: type} = request) when is_map_key(@requests, type) do
    {name, members} = Map.fetch!(@requests, type)
    fields = Map.delete(request, :type)

    check_members(fields, members, name)
    written = fields |> Enum.sort_by(&to_string(elem(&1, 0))) |> Enum.map(&write(type, &1))
    if type == :spawn, do: check_spec(fields)

    line =
      [{"type", name}, {"v", @version} | written]
      |> Enum.sort_by(&elem(&1, 0))
      |> Jason.OrderedObject.new()
      |> Jason.encode_to_iodata!()

    if IO.iodata_length(line) > @max_line_bytes,
      do: raise(ArgumentError, "the request is longer than #{@max_line_bytes} bytes")

    [line, ?\n]
  end

  def encode(%{type: _type}), do: raise(ArgumentError, "type is not a request type")
  def encode(_request), do: raise(ArgumentError, "type is missing")

  @doc """
  The reply one line carries, with or without the newline that ends it,
  or the first reason it is not one (`t:reason/0`).
  """
  @spec decode_reply(term()) :: {:ok, reply()} | {:error, reason()}
  def decode_reply(line) when is_binary(line) do
    line = trim_newline(line)

    with :ok <- within_line(line),
         {:ok, object} <- json_object(line),
         :ok <- known_version(object),
         {:ok, type, members} <- known_reply(object),
         {:ok, read} <- read_members(members, Map.drop(object, ["v", "type"]), type) do
      reply(type, read)
    end
  end

  def decode_reply(_line), do: {:error, :malformed}

  # ============================================================================
  # Writing a request
  # ============================================================================

  defp check_members(fields, members, type_name) do
    case Enum.sort(Map.keys(fields) -- Keyword.keys(members)) do
      [] -> :ok
      [extra | _rest] -> raise ArgumentError, "#{extra} is not a member of a #{type_name} request"
    end

    for {member, :required} <- members,
        not Map.has_key?(fields, member),
        do: raise(ArgumentError, "#{member} is missing")

    :ok
  end

  defp member_names(members), do: Enum.map(members, fn {member, _} -> Atom.to_string(member) end)

  defp write(_type, {:id, id}), do: {"id", matching!(@id, "id", id)}
  defp write(_type, {:pool, pool}), do: {"pool", matching!(@pool, "pool", pool)}
  defp write(_type, {:spawn_id, id}), do: {"spawn_id", matching!(@spawn_id, "spawn_id", id)}
  defp write(:spawn, {:argv, argv}), do: {"argv", argv!(argv)}
  defp write(:spawn, {:env, env}), do: {"env", env!(env)}
  defp write(:spawn, {:rlimits, rlimits}), do: {"rlimits", rlimits!(rlimits)}
  defp write(:spawn, {:attach, attach}), do: {"attach", attach!(attach)}

  defp write(:spawn, {:memory_bytes, bytes})
       when is_integer(bytes) and bytes >= @min_memory_bytes and bytes <= @max_memory_bytes,
       do: {"memory_bytes", bytes}

  defp write(:spawn, {:control, control}) when is_boolean(control), do: {"control", control}
  defp write(:signal, {:sig, sig}) when sig in @signals, do: {"sig", sig}

  defp write(:release, {:grace_ms, grace})
       when is_integer(grace) and grace >= 0 and grace <= @max_grace_ms,
       do: {"grace_ms", grace}

  defp write(_type, {member, _value}), do: invalid!(member)

  defp argv!(argv) when is_list(argv) and argv != [] and length(argv) <= @max_args do
    valid? = fn arg -> text?(arg) and not String.contains?(arg, <<0>>) end
    if Enum.all?(argv, valid?) and hd(argv) != "", do: argv, else: invalid!("argv")
  end

  defp argv!(_argv), do: invalid!("argv")

  # An environment's names and values are checked without quoting either.
  defp env!(env) when is_map(env) and not is_struct(env) and map_size(env) <= @max_env do
    if Enum.all?(env, fn {name, value} -> env_name?(name) and env_value?(value) end),
      do: env |> Enum.sort() |> Jason.OrderedObject.new(),
      else: invalid!("env")
  end

  defp env!(_env), do: invalid!("env")

  defp env_name?(name) do
    is_binary(name) and Regex.match?(@env_name, name) and name not in @reserved_env and
      not String.starts_with?(name, @reserved_env_prefixes)
  end

  defp env_value?(value) do
    text?(value) and byte_size(value) <= @max_value_bytes and not String.contains?(value, <<0>>)
  end

  defp rlimits!(rlimits) when is_map(rlimits) and not is_struct(rlimits) do
    case Enum.sort(Map.keys(rlimits) -- Keyword.keys(@rlimits)) do
      [] -> :ok
      [extra | _rest] -> invalid!("rlimits.#{extra}")
    end

    @rlimits
    |> Enum.filter(fn {limit, _bounds} -> Map.has_key?(rlimits, limit) end)
    |> Enum.map(fn {limit, {least, most}} ->
      case Map.fetch!(rlimits, limit) do
        value when is_integer(value) and value >= least and value <= most -> {limit, value}
        _value -> invalid!("rlimits.#{limit}")
      end
    end)
    |> Jason.OrderedObject.new()
  end

  defp rlimits!(_rlimits), do: invalid!("rlimits")

  defp attach!(%{path: path, token: token} = attach) when map_size(attach) == 2 do
    unless clean_socket_path?(path), do: invalid!("attach.path")
    Jason.OrderedObject.new(path: path, token: matching!(@token, "attach.token", token))
  end

  defp attach!(_attach), do: invalid!("attach")

  # An absolute path as the keeper's `filepath.Clean` leaves it: no empty,
  # `.` or `..` segment and no trailing slash, short enough for a unix
  # socket's address.
  defp clean_socket_path?(path) do
    text?(path) and byte_size(path) <= @max_socket_path and not String.contains?(path, <<0>>) and
      String.starts_with?(path, "/") and
      (path == "/" or
         path |> String.split("/") |> tl() |> Enum.all?(&(&1 not in ["", ".", ".."])))
  end

  # The keeper's bound on a spawn's argv and env together, as it counts it.
  defp check_spec(fields) do
    argv = Enum.reduce(Map.fetch!(fields, :argv), 0, &(&2 + byte_size(&1) + 1))

    env =
      fields
      |> Map.get(:env, %{})
      |> Enum.reduce(0, fn {name, value}, total ->
        total + byte_size(name) + byte_size(value) + 2
      end)

    if argv + env > @max_spec_bytes, do: invalid!("argv")
    :ok
  end

  defp matching!(regex, member, value) do
    if text?(value) and Regex.match?(regex, value), do: value, else: invalid!(member)
  end

  defp text?(value), do: is_binary(value) and String.valid?(value)

  @spec invalid!(atom() | String.t()) :: no_return()
  defp invalid!(member), do: raise(ArgumentError, "#{member} is not of its type or bound")

  # ============================================================================
  # Reading a reply
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

  defp known_reply(%{"type" => name}) when is_map_key(@replies, name) do
    {type, members} = Map.fetch!(@replies, name)
    {:ok, type, members}
  end

  defp known_reply(_object), do: {:error, :unknown_type}

  defp read_members(members, object, type) do
    optional = Map.get(@optional_reply_members, type, [])

    case Enum.sort(Map.keys(object) -- member_names(members)) do
      [] ->
        Enum.reduce_while(members, {:ok, %{}}, fn {member, kind}, {:ok, read} ->
          case read_member(object, member, kind, member in optional) do
            {:ok, value} -> {:cont, {:ok, Map.put(read, member, value)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      [unknown | _rest] ->
        {:error, {:unknown_field, unknown}}
    end
  end

  defp read_member(object, member, kind, optional?) do
    name = Atom.to_string(member)

    case Map.fetch(object, name) do
      {:ok, value} -> read(kind, name, value)
      :error when optional? -> {:ok, nil}
      :error -> {:error, {:missing_field, name}}
    end
  end

  defp read({:nullable, _kind}, _name, nil), do: {:ok, nil}
  defp read({:nullable, kind}, name, value), do: read(kind, name, value)
  defp read(:id, name, value) when is_binary(value), do: reading(@id, name, value)
  defp read(:pool, name, value) when is_binary(value), do: reading(@pool, name, value)
  defp read(:spawn_id, name, value) when is_binary(value), do: reading(@spawn_id, name, value)
  defp read(:code, name, value) when is_binary(value), do: reading(@code, name, value)
  defp read(:signal, name, value) when is_binary(value), do: reading(@signal, name, value)
  defp read(:integer, _name, value) when is_integer(value), do: {:ok, value}

  defp read(:count, _name, value) when is_integer(value) and value >= 0 and value <= @max_count,
    do: {:ok, value}

  defp read(:count, name, value) when is_integer(value), do: {:error, {:invalid_field, name}}
  defp read(:boolean, _name, value) when is_boolean(value), do: {:ok, value}
  defp read(_kind, name, _value), do: {:error, {:wrong_type, name}}

  defp reading(regex, name, value) do
    if Regex.match?(regex, value), do: {:ok, value}, else: {:error, {:invalid_field, name}}
  end

  defp reply(:spawned, %{id: id, spawn_id: spawn_id, uid: uid, pid: pid}),
    do: {:ok, {:spawned, id, spawn_id, uid, pid}}

  defp reply(:error, %{id: id, spawn_id: spawn_id, code: code}),
    do: {:ok, {:error, id, spawn_id, code}}

  defp reply(:exited, %{spawn_id: spawn_id, code: code, signal: nil, memory_exceeded: exceeded})
       when code != nil,
       do: {:ok, {:exited, spawn_id, {:status, code}, exceeded}}

  defp reply(:exited, %{spawn_id: spawn_id, code: nil, signal: signal, memory_exceeded: exceeded})
       when signal != nil,
       do: {:ok, {:exited, spawn_id, {:signal, signal}, exceeded}}

  defp reply(:exited, _read), do: {:error, :ambiguous_exit}

  defp reply(:released, %{spawn_id: spawn_id}), do: {:ok, {:released, spawn_id}}

  defp reply(:pool, %{id: id, pool: pool, size: size, free: free, quarantined: quarantined}),
    do: {:ok, {:pool, id, pool, size, free, quarantined}}
end
