# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.RunnerRelay do
  @moduledoc """
  The relay between a runner and its worker service: the one path a runner
  in a network namespace of its own has to CYFR's host API and to the
  addresses CYFR pins for its guests. The keeper gives every spawn of an
  isolated pool this channel as a socketpair on its file descriptor 4,
  beside `Prima.RunnerControl` on file descriptor 3, and carries it over
  the attach connection as the relay stream (`Prima.KeeperProtocol`), so
  control lines and relay frames never share a stream. The keeper sends
  nothing on that stream until the service has opened it, and the service
  opens it with a zero-length frame before it reads a runner's first call.
  `tests/fixtures/runner_relay.json` holds the vectors every encoder and
  decoder of it reproduces.

  ## Frames

  A frame is a 4-byte big-endian length and that many bytes of one JSON
  object, at most `max_frame_bytes/0`. Every frame carries `v` (1),
  `attempt` (the attempt it acts for), `seq` (its place among the frames
  its sender sent on this channel, from 0 in each direction) and `kind`,
  then the kind's members, always all of them, in this order:

  Runner to service:

    * `host_call` — `op` (a `Prima.HostAPI` callback a runner makes),
      `header` (the call's signed header, `Prima.WorkerWire.auth_header/0`'s
      value: printable ASCII, spaces included, at most
      `Prima.WorkerAuth.max_host_call_header_bytes/0`) and `body` (the
      sealed call). The runner signs and seals it under the attempt's keys;
      the service, holding the same keys, verifies the header names the
      frame's attempt, its runner, its boot and its member
      (`Prima.WorkerAuth.verify_host_call_header_under/3`), posts it
      unchanged to the member the attempt's assignment names and answers
      it once.
    * `fetch` — `pin` (the id of a pin, `Prima.PinnedTarget`), `method`,
      `path` (the path and query, from `/`), `headers` and `body`. The
      service connects to the pin's address itself, and refuses a pin it
      did not see CYFR grant to the frame's attempt in an `egress_pin`
      answer it relayed: the runner names a pin, never an address.
    * `credit` — `re` (the `fetch` it is for) and `bytes`: how many more
      bytes of that fetch's answer body the runner will take.

  Service to runner:

    * `host_answer` — `re` (the `host_call` it answers), `status` (CYFR's
      HTTP status, or null when no answer reached the service: a transport
      failure, a timeout or an answer past the bound) and `body`.
    * `fetch_chunk` — `re` (the `fetch`), `status` and `headers` (the
      answer's, on the first chunk of a fetch and null on every later one)
      and `body`, the next bytes of the answer body.
    * `fetch_end` — `re` (the `fetch`) and `error`: null for an answer
      delivered whole, else a code saying why the fetch ended early. It
      may come before any chunk.

  Either side:

    * `close` — `reason`, a code (`close_code/1`); the sender closes the
      channel after it.

  A body travels in standard base64 with padding and is at most
  `max_body_bytes/0` decoded, `Prima.HostAPI.max_answer_bytes/0`.

  ## Flow control

  The service sends a fetch's answer body only against credit the runner
  granted for that fetch: `initial_credit/0` when the fetch is sent, and
  each `credit` frame's `bytes` after. A `fetch_chunk` whose body is
  larger than the credit outstanding is never sent (`encode/2` answers
  `{:error, :credit_exceeded}`), and one received closes the channel.

  ## The channel's state

  A channel (`t:t/0`) is one side's view: `new/2` opens it for the
  assigned attempt, and `admit/2` adds each attempt of the runner's
  subtree the channel then carries. `encode/2` numbers what a side sends
  and `decode/2` checks what it receives against the same state, so each
  side knows the calls still unanswered, the fetches still open and each
  fetch's credit.

  ## Decoding

  `decode/2` answers the complete frames at the head of a buffer and the
  bytes after them, or the first reason the channel closes, in this order:

    1. `:frame_too_large` — a length above `max_frame_bytes/0`, as soon as
       the length is in;
    2. `:malformed` — the frame is not one JSON object;
    3. `:bad_version` — `v` is absent or is not `1`;
    4. `:unknown_kind` — `kind` is absent or is not one of the seven;
    5. `:wrong_direction` — a kind the peer does not send;
    6. `{:unknown_field, name}` — a member the kind does not carry (the
       first, by name);
    7. per member, `attempt`, `seq`, then the kind's in order:
       `{:missing_field, name}`, `{:wrong_type, name}`,
       `{:invalid_field, name}`, or `:body_too_large` for a body above
       `max_body_bytes/0`;
    8. `:out_of_order` — a `seq` other than the next one;
    9. `:unknown_attempt` — an attempt the channel does not carry, or not
       the one of the frame `re` names;
    10. `:unknown_reference` — an `re` naming no unanswered call or open
        fetch;
    11. `{:invalid_field, "status"}` — a chunk's head where it does not
        belong or missing where it does;
    12. `:credit_exceeded` — a chunk larger than the fetch's credit.

  The channel is at fault on any refusal, and nothing after it is read.
  """

  alias Prima.{HostAPI, PinnedTarget}

  @version 1

  @max_body_bytes HostAPI.max_answer_bytes()

  # A frame holds the largest body in base64 and, beside it, the envelope
  # and a fetch's head, whose own bounds (@max_headers of at most
  # @max_header_name_bytes and @max_header_value_bytes, a path of at most
  # @max_path_bytes) keep them under the margin.
  @max_frame_bytes 8 * 1024 * 1024
  @max_headers 128
  @max_header_name_bytes 256
  @max_header_value_bytes 8192
  @max_path_bytes 8192
  @max_signed_header_bytes Prima.WorkerAuth.max_host_call_header_bytes()

  # 2^53 − 1: the largest integer every JSON reader holds exactly.
  @max_integer 9_007_199_254_740_991

  @ops HostAPI.callbacks() -- [:runner_exited]
  @op_by_name Map.new(@ops, &{Atom.to_string(&1), &1})
  @methods ~w(GET HEAD POST PUT PATCH DELETE OPTIONS)

  @id ~r/\A[\x21-\x7E]{1,256}\z/
  @signed_header ~r/\A[\x20-\x7E]+\z/
  @path ~r/\A\/[\x21-\x7E]*\z/
  @code ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @header_name ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
  @header_value ~r/\A[^\x00-\x08\x0A-\x1F\x7F]*\z/u

  # Every kind, its wire name, its sender and its members in wire order.
  @kinds [
    {:host_call, :runner, [op: :op, header: :signed_header, body: :body]},
    {:host_answer, :service, [re: :seq, status: {:nullable, :status}, body: :body]},
    {:fetch, :runner, [pin: :pin, method: :method, path: :path, headers: :headers, body: :body]},
    {:fetch_chunk, :service,
     [re: :seq, status: {:nullable, :status}, headers: {:nullable, :headers}, body: :body]},
    {:fetch_end, :service, [re: :seq, error: {:nullable, :code}]},
    {:credit, :runner, [re: :seq, bytes: :credit]},
    {:close, :either, [reason: :code]}
  ]

  @by_kind Map.new(@kinds, fn {kind, sender, members} -> {kind, {sender, members}} end)
  @by_name Map.new(@kinds, fn {kind, _sender, _members} -> {Atom.to_string(kind), kind} end)

  @enforce_keys [:side, :attempts]
  defstruct [:side, :attempts, sent: 0, received: 0, calls: %{}, fetches: %{}]

  @typedoc "Which end of the channel: the runner's or its worker service's."
  @type side :: :runner | :service

  @typedoc "A frame kind."
  @type kind :: :host_call | :host_answer | :fetch | :fetch_chunk | :fetch_end | :credit | :close

  @typedoc "An answer or request header: its name and its value."
  @type header :: {String.t(), String.t()}

  @typedoc """
  A frame, as `encode/2` takes it (without `seq`, which the channel
  assigns) and `decode/2` answers it (with `seq`): its `kind`, its
  `attempt` and its kind's members, `op` as the callback's atom and every
  body as its bytes.
  """
  @type frame :: %{
          required(:kind) => kind(),
          required(:attempt) => String.t(),
          optional(:seq) => non_neg_integer(),
          optional(atom()) => term()
        }

  @typedoc "Why a channel closes (see the module's decoding order)."
  @type reason ::
          :frame_too_large
          | :malformed
          | :bad_version
          | :unknown_kind
          | :wrong_direction
          | {:unknown_field, String.t()}
          | {:missing_field, String.t()}
          | {:wrong_type, String.t()}
          | {:invalid_field, String.t()}
          | :body_too_large
          | :out_of_order
          | :unknown_attempt
          | :unknown_reference
          | :credit_exceeded

  @typedoc "One side's view of a channel."
  @type t :: %__MODULE__{
          side: side(),
          attempts: MapSet.t(String.t()),
          sent: non_neg_integer(),
          received: non_neg_integer(),
          calls: %{non_neg_integer() => String.t()},
          fetches: %{
            non_neg_integer() => %{
              attempt: String.t(),
              credit: non_neg_integer(),
              headed: boolean()
            }
          }
        }

  @doc "The protocol version every frame carries as `v`."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The most bytes a body carries, decoded: `Prima.HostAPI.max_answer_bytes/0`."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @doc "The most bytes a frame's JSON spans, its length prefix excluded."
  @spec max_frame_bytes() :: pos_integer()
  def max_frame_bytes, do: @max_frame_bytes

  @doc "The credit a fetch starts with: one body of `max_body_bytes/0`."
  @spec initial_credit() :: pos_integer()
  def initial_credit, do: @max_body_bytes

  @doc "The frame kinds, in the order the module documents them."
  @spec kinds() :: [kind()]
  def kinds, do: Enum.map(@kinds, &elem(&1, 0))

  @doc "Which side sends a frame of `kind`: `:runner`, `:service` or `:either`."
  @spec sender(kind()) :: side() | :either
  def sender(kind) when is_map_key(@by_kind, kind), do: @by_kind |> Map.fetch!(kind) |> elem(0)

  @doc "The host API callbacks a `host_call` may name."
  @spec ops() :: [atom()]
  def ops, do: @ops

  @doc """
  The code a `close` frame carries for `reason`: the reason's own name, or
  `malformed` for a refusal naming a member. `:done` closes a channel
  whose work is over.
  """
  @spec close_code(reason() | :done) :: String.t()
  def close_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  def close_code({_refusal, _name}), do: "malformed"

  @doc "The channel as `side` opens it, carrying the assigned `attempt`."
  @spec new(side(), String.t()) :: t()
  def new(side, attempt) when side in [:runner, :service] do
    unless id?(attempt), do: invalid("attempt")
    %__MODULE__{side: side, attempts: MapSet.new([attempt])}
  end

  @doc "The channel carrying `attempt` too: another attempt of the runner's subtree."
  @spec admit(t(), String.t()) :: t()
  def admit(%__MODULE__{} = channel, attempt) do
    unless id?(attempt), do: invalid("attempt")
    %{channel | attempts: MapSet.put(channel.attempts, attempt)}
  end

  @doc """
  The credit the service may still spend on fetch `re`'s answer body, or
  nil for a fetch that is not open.
  """
  @spec credit(t(), non_neg_integer()) :: non_neg_integer() | nil
  def credit(%__MODULE__{fetches: fetches}, re) do
    case Map.fetch(fetches, re) do
      {:ok, fetch} -> fetch.credit
      :error -> nil
    end
  end

  # ============================================================================
  # Encoding
  # ============================================================================

  @doc """
  The bytes of `frame` as the next frame this side sends, and the channel
  after it. A frame the channel's state refuses — an attempt it does not
  carry, an `re` naming nothing open, a chunk past the fetch's credit —
  is `{:error, reason}` and changes nothing. A frame of a kind this side
  does not send, a member it lacks or does not carry, or a value
  `decode/2` would refuse raises `ArgumentError`, since it is the
  caller's own data.
  """
  @spec encode(t(), frame()) :: {:ok, iodata(), t()} | {:error, reason()}
  def encode(%__MODULE__{} = channel, %{kind: kind} = frame) when is_map_key(@by_kind, kind) do
    {sender, members} = Map.fetch!(@by_kind, kind)

    unless sender in [channel.side, :either],
      do: raise(ArgumentError, "a #{channel.side} does not send #{kind}")

    fields = Map.drop(frame, [:kind])

    case Map.keys(fields) -- [:attempt | Keyword.keys(members)] do
      [] -> :ok
      [extra | _rest] -> raise ArgumentError, "#{extra} is not a member of #{kind}"
    end

    attempt = Map.get(fields, :attempt)
    unless id?(attempt), do: invalid("attempt")

    written =
      Enum.map(members, fn {member, type} ->
        case Map.fetch(fields, member) do
          {:ok, value} -> {Atom.to_string(member), write(type, Atom.to_string(member), value)}
          :error -> raise ArgumentError, "#{member} is missing"
        end
      end)

    read = Map.put(fields, :seq, channel.sent)

    with {:ok, channel} <- step(channel, kind, read) do
      json =
        [{"v", @version}, {"attempt", attempt}, {"seq", read.seq}, {"kind", Atom.to_string(kind)}]
        |> Kernel.++(written)
        |> Jason.OrderedObject.new()
        |> Jason.encode_to_iodata!()

      length = IO.iodata_length(json)
      if length > @max_frame_bytes, do: raise(ArgumentError, "the frame is over the bound")
      {:ok, [<<length::32>>, json], %{channel | sent: channel.sent + 1}}
    end
  end

  def encode(%__MODULE__{}, _frame), do: raise(ArgumentError, "kind is not a frame kind")

  defp write(:op, _name, op) when op in @ops, do: Atom.to_string(op)
  defp write(:signed_header, name, value), do: write_matching(@signed_header, name, value)

  defp write(:pin, name, value),
    do: if(PinnedTarget.valid_id?(value), do: value, else: invalid(name))

  defp write(:method, _name, value) when value in @methods, do: value
  defp write(:path, name, value), do: write_matching(@path, name, value)
  defp write(:code, name, value), do: write_matching(@code, name, value)

  defp write(:seq, _name, value) when is_integer(value) and value >= 0 and value <= @max_integer,
    do: value

  defp write(:status, _name, value) when is_integer(value) and value in 100..599, do: value

  defp write(:credit, _name, value)
       when is_integer(value) and value >= 1 and value <= @max_body_bytes,
       do: value

  defp write(:body, _name, value) when is_binary(value) and byte_size(value) <= @max_body_bytes,
    do: Base.encode64(value)

  defp write(:headers, name, headers) when is_list(headers) do
    if headers?(headers),
      do: Enum.map(headers, fn {header, value} -> [header, value] end),
      else: invalid(name)
  end

  defp write({:nullable, _type}, _name, nil), do: nil
  defp write({:nullable, type}, name, value), do: write(type, name, value)
  defp write(_type, name, _value), do: invalid(name)

  defp write_matching(regex, name, value) do
    if is_binary(value) and String.valid?(value) and within?(name, value) and
         Regex.match?(regex, value),
       do: value,
       else: invalid(name)
  end

  defp within?("header", value), do: byte_size(value) <= @max_signed_header_bytes
  defp within?("path", value), do: byte_size(value) <= @max_path_bytes
  defp within?(_name, _value), do: true

  defp headers?(headers) do
    length(headers) <= @max_headers and
      Enum.all?(headers, fn
        {name, value} -> header_name?(name) and header_value?(value)
        _other -> false
      end)
  end

  defp header_name?(name) do
    is_binary(name) and byte_size(name) <= @max_header_name_bytes and
      Regex.match?(@header_name, name)
  end

  defp header_value?(value) do
    is_binary(value) and byte_size(value) <= @max_header_value_bytes and String.valid?(value) and
      Regex.match?(@header_value, value)
  end

  @spec invalid(String.t()) :: no_return()
  defp invalid(name), do: raise(ArgumentError, "#{name} is not of its type or bound")

  # ============================================================================
  # Decoding
  # ============================================================================

  @doc """
  The complete frames at the head of `buffer`, in order, the bytes after
  them, which wait for more, and the channel after them; or the first
  reason the channel closes (`t:reason/0`, the module's decoding order).
  """
  @spec decode(t(), binary()) :: {:ok, [frame()], binary(), t()} | {:error, reason()}
  def decode(%__MODULE__{} = channel, buffer) when is_binary(buffer),
    do: decode(channel, buffer, [])

  defp decode(_channel, <<length::32, _rest::binary>>, _frames) when length > @max_frame_bytes,
    do: {:error, :frame_too_large}

  defp decode(channel, <<length::32, json::binary-size(length), rest::binary>>, frames) do
    with {:ok, frame} <- read_frame(channel, json),
         {:ok, channel} <- step(channel, frame.kind, frame) do
      decode(%{channel | received: channel.received + 1}, rest, [frame | frames])
    end
  end

  defp decode(channel, rest, frames), do: {:ok, Enum.reverse(frames), rest, channel}

  defp read_frame(channel, json) do
    with {:ok, object} <- json_object(json),
         :ok <- known_version(object),
         {:ok, kind, sender, members} <- known_kind(object),
         :ok <- from_peer(channel, sender),
         members = [attempt: :id, seq: :seq] ++ members,
         :ok <- no_unknown_field(members, Map.drop(object, ["v", "kind"])),
         {:ok, frame} <- read_members(members, object),
         :ok <- in_order(channel, frame) do
      {:ok, Map.put(frame, :kind, kind)}
    end
  end

  defp json_object(json) do
    case Jason.decode(json) do
      {:ok, %{} = object} -> {:ok, object}
      _other -> {:error, :malformed}
    end
  end

  defp known_version(%{"v" => @version}), do: :ok
  defp known_version(_object), do: {:error, :bad_version}

  defp known_kind(%{"kind" => name}) when is_map_key(@by_name, name) do
    kind = Map.fetch!(@by_name, name)
    {sender, members} = Map.fetch!(@by_kind, kind)
    {:ok, kind, sender, members}
  end

  defp known_kind(_object), do: {:error, :unknown_kind}

  defp from_peer(%__MODULE__{side: side}, sender) when sender != side, do: :ok
  defp from_peer(_channel, _sender), do: {:error, :wrong_direction}

  defp no_unknown_field(members, object) do
    known = Enum.map(members, fn {member, _type} -> Atom.to_string(member) end)

    case Enum.sort(Map.keys(object) -- known) do
      [] -> :ok
      [unknown | _rest] -> {:error, {:unknown_field, unknown}}
    end
  end

  defp read_members(members, object) do
    Enum.reduce_while(members, {:ok, %{}}, fn {member, type}, {:ok, read} ->
      name = Atom.to_string(member)

      with {:ok, value} <- fetch_member(object, name),
           {:ok, value} <- read(type, name, value) do
        {:cont, {:ok, Map.put(read, member, value)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_member(object, name) do
    case Map.fetch(object, name) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_field, name}}
    end
  end

  defp in_order(%__MODULE__{received: seq}, %{seq: seq}), do: :ok
  defp in_order(_channel, _frame), do: {:error, :out_of_order}

  defp read({:nullable, _type}, _name, nil), do: {:ok, nil}
  defp read({:nullable, type}, name, value), do: read(type, name, value)
  defp read(:id, name, value) when is_binary(value), do: matching(@id, name, value)

  defp read(:op, name, value) when is_binary(value) do
    case Map.fetch(@op_by_name, value) do
      {:ok, op} -> {:ok, op}
      :error -> {:error, {:invalid_field, name}}
    end
  end

  defp read(:signed_header, name, value) when is_binary(value) do
    if byte_size(value) <= @max_signed_header_bytes,
      do: matching(@signed_header, name, value),
      else: {:error, {:invalid_field, name}}
  end

  defp read(:pin, name, value) when is_binary(value) do
    if PinnedTarget.valid_id?(value), do: {:ok, value}, else: {:error, {:invalid_field, name}}
  end

  defp read(:method, name, value) when is_binary(value) do
    if value in @methods, do: {:ok, value}, else: {:error, {:invalid_field, name}}
  end

  defp read(:path, name, value) when is_binary(value) do
    if byte_size(value) <= @max_path_bytes,
      do: matching(@path, name, value),
      else: {:error, {:invalid_field, name}}
  end

  defp read(:code, name, value) when is_binary(value), do: matching(@code, name, value)

  defp read(:seq, _name, value) when is_integer(value) and value >= 0 and value <= @max_integer,
    do: {:ok, value}

  defp read(:status, _name, value) when is_integer(value) and value in 100..599, do: {:ok, value}

  defp read(:credit, _name, value)
       when is_integer(value) and value >= 1 and value <= @max_body_bytes,
       do: {:ok, value}

  defp read(type, name, value) when type in [:seq, :status, :credit] and is_integer(value),
    do: {:error, {:invalid_field, name}}

  defp read(:body, _name, value)
       when is_binary(value) and byte_size(value) > div(@max_body_bytes + 2, 3) * 4,
       do: {:error, :body_too_large}

  defp read(:body, name, value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, bytes} when byte_size(bytes) <= @max_body_bytes -> {:ok, bytes}
      {:ok, _bytes} -> {:error, :body_too_large}
      :error -> {:error, {:invalid_field, name}}
    end
  end

  defp read(:headers, name, value) when is_list(value) do
    headers =
      Enum.map(value, fn
        [header, header_value] -> {header, header_value}
        _other -> :error
      end)

    if headers?(headers), do: {:ok, headers}, else: {:error, {:invalid_field, name}}
  end

  defp read(_type, name, _value), do: {:error, {:wrong_type, name}}

  defp matching(regex, name, value) do
    if String.valid?(value) and Regex.match?(regex, value),
      do: {:ok, value},
      else: {:error, {:invalid_field, name}}
  end

  # ============================================================================
  # The channel's state
  # ============================================================================

  # One frame's effect on the channel, the same whichever side sent it: a
  # call or a fetch opens, an answer or an end closes what it names, a
  # chunk spends its fetch's credit and a credit frame grants more.
  defp step(channel, kind, %{attempt: attempt} = frame) do
    if MapSet.member?(channel.attempts, attempt),
      do: step_kind(channel, kind, frame),
      else: {:error, :unknown_attempt}
  end

  defp step_kind(channel, :host_call, %{seq: seq, attempt: attempt}),
    do: {:ok, %{channel | calls: Map.put(channel.calls, seq, attempt)}}

  defp step_kind(channel, :host_answer, %{re: re, attempt: attempt}) do
    case Map.fetch(channel.calls, re) do
      {:ok, ^attempt} -> {:ok, %{channel | calls: Map.delete(channel.calls, re)}}
      {:ok, _other} -> {:error, :unknown_attempt}
      :error -> {:error, :unknown_reference}
    end
  end

  defp step_kind(channel, :fetch, %{seq: seq, attempt: attempt}) do
    fetch = %{attempt: attempt, credit: @max_body_bytes, headed: false}
    {:ok, %{channel | fetches: Map.put(channel.fetches, seq, fetch)}}
  end

  defp step_kind(channel, :fetch_chunk, %{re: re} = frame) do
    with {:ok, fetch} <- open_fetch(channel, frame),
         :ok <- head_in_place(fetch, frame),
         :ok <- within_credit(fetch, frame.body) do
      fetch = %{fetch | credit: fetch.credit - byte_size(frame.body), headed: true}
      {:ok, %{channel | fetches: Map.put(channel.fetches, re, fetch)}}
    end
  end

  defp step_kind(channel, :fetch_end, %{re: re} = frame) do
    with {:ok, _fetch} <- open_fetch(channel, frame),
         do: {:ok, %{channel | fetches: Map.delete(channel.fetches, re)}}
  end

  defp step_kind(channel, :credit, %{re: re, bytes: bytes} = frame) do
    with {:ok, fetch} <- open_fetch(channel, frame) do
      fetch = %{fetch | credit: min(fetch.credit + bytes, @max_integer)}
      {:ok, %{channel | fetches: Map.put(channel.fetches, re, fetch)}}
    end
  end

  defp step_kind(channel, :close, _frame), do: {:ok, channel}

  defp open_fetch(channel, %{re: re, attempt: attempt}) do
    case Map.fetch(channel.fetches, re) do
      {:ok, %{attempt: ^attempt} = fetch} -> {:ok, fetch}
      {:ok, _other} -> {:error, :unknown_attempt}
      :error -> {:error, :unknown_reference}
    end
  end

  # The first chunk of a fetch carries the answer's status and headers and
  # no later one does.
  defp head_in_place(%{headed: false}, %{status: status, headers: headers})
       when is_integer(status) and is_list(headers),
       do: :ok

  defp head_in_place(%{headed: true}, %{status: nil, headers: nil}), do: :ok
  defp head_in_place(_fetch, _frame), do: {:error, {:invalid_field, "status"}}

  defp within_credit(%{credit: credit}, body) when byte_size(body) <= credit, do: :ok
  defp within_credit(_fetch, _body), do: {:error, :credit_exceeded}

  defp id?(value), do: is_binary(value) and Regex.match?(@id, value)
end
