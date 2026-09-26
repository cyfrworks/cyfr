# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends.Relay do
  @moduledoc """
  The stdio side of one backend's process, as data: the bytes its relay
  connection carries in, the JSON-RPC lines its stdout forms, the calls
  awaiting an answer, and the tail of its stderr. State in, state out; no
  process.

  `frames/2` takes an attach connection's bytes as they arrive and decodes
  them with `Prima.KeeperProtocol.parse_frames/1`: stdout and stderr go on
  as `stdout/2` and `stderr/2` take them, a zero-length frame ends
  nothing, and a frame the codec refuses or on any other stream is the
  relay's fault (`:relay_protocol`). A launcher that has decoded the frames
  already hands their payloads to `stdout/2` and `stderr/2` directly.

  Stdout is newline-delimited JSON-RPC. A line, or the part of one that
  has no newline yet, longer than `Prima.LocusBackends.max_frame_bytes/0`
  is `:frame_too_large`, and the backend's process is killed for it. Each
  whole line that decodes to a JSON object is one of:

    * a message carrying `method`: the backend's own request or
      notification (`{:child, id | nil, method}`), which never answers a
      call, whatever its `id`, since the backend counts its ids apart;
    * a message carrying `id` and `result` or `error`, naming a pending
      call by the id `request/4` minted: the call's answer
      (`{:answer, tag, {:result, result} | {:error, error}}`). A string
      id names the numeric one it spells, as JSON-RPC peers echo either;
    * anything else, dropped and counted (`dropped/1`).

  Stderr is never parsed: the last `Prima.LocusBackends.stderr_tail_bytes/0`
  bytes are what a status reports, and `stderr_tail_slack_bytes/0` more
  are kept so a credential split by the cut is masked before the cut is
  taken (`stderr_tail/2`).
  """

  alias Prima.{KeeperProtocol, LocusBackends}

  defstruct frames: "",
            line: "",
            stderr: "",
            pending: %{},
            next_id: 0,
            dropped: 0,
            max_frame_bytes: nil,
            tail_bytes: nil,
            slack_bytes: nil

  @typedoc "A pending call's own term, answered back with its answer."
  @type tag :: term()

  @type t :: %__MODULE__{
          frames: binary(),
          line: binary(),
          stderr: binary(),
          pending: %{pos_integer() => tag()},
          next_id: non_neg_integer(),
          dropped: non_neg_integer(),
          max_frame_bytes: pos_integer(),
          tail_bytes: pos_integer(),
          slack_bytes: non_neg_integer()
        }

  @typedoc "What a backend's stdout said."
  @type event ::
          {:answer, tag(), {:result, term()} | {:error, term()}}
          | {:child, term(), String.t()}

  @doc """
  A relay with no bytes seen. Options, each defaulting to
  `Prima.LocusBackends`' bound of the same name: `:max_frame_bytes`,
  `:stderr_tail_bytes`, `:stderr_tail_slack_bytes`.
  """
  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = Map.new(opts)

    %__MODULE__{
      max_frame_bytes: Map.get(opts, :max_frame_bytes, LocusBackends.max_frame_bytes()),
      tail_bytes: Map.get(opts, :stderr_tail_bytes, LocusBackends.stderr_tail_bytes()),
      slack_bytes:
        Map.get(opts, :stderr_tail_slack_bytes, LocusBackends.stderr_tail_slack_bytes())
    }
  end

  @doc """
  The relay for the backend's next process: stdout, frames and pending
  calls start over, ids from 1 again; the stderr kept and the count of
  dropped messages carry on.
  """
  @spec restart(t()) :: t()
  def restart(%__MODULE__{} = relay),
    do: %{relay | frames: "", line: "", pending: %{}, next_id: 0}

  # ————— calls —————

  @doc """
  A call of `method` with `params` (none when nil), pending under a newly
  minted id with `tag`: the line to write to the backend's stdin, the id,
  and the relay.
  """
  @spec request(t(), String.t(), term(), tag()) :: {iolist(), pos_integer(), t()}
  def request(%__MODULE__{} = relay, method, params, tag) when is_binary(method) do
    id = relay.next_id + 1
    message = with_params(%{jsonrpc: "2.0", id: id, method: method}, params)

    {[Jason.encode_to_iodata!(message), ?\n], id,
     %{relay | next_id: id, pending: Map.put(relay.pending, id, tag)}}
  end

  @doc "A notification of `method`, which nothing answers: the line to write."
  @spec notification(String.t(), term()) :: iolist()
  def notification(method, params \\ nil) when is_binary(method),
    do: [Jason.encode_to_iodata!(with_params(%{jsonrpc: "2.0", method: method}, params)), ?\n]

  @doc "An answer to the backend's own request `id`: the line to write."
  @spec reply_error(term(), integer(), String.t()) :: iolist()
  def reply_error(id, code, message) when is_integer(code) and is_binary(message),
    do: [
      Jason.encode_to_iodata!(%{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}),
      ?\n
    ]

  defp with_params(message, nil), do: message
  defp with_params(message, params), do: Map.put(message, :params, params)

  @doc "The pending call `id`'s tag, which is pending no more, or nil."
  @spec cancel(t(), pos_integer()) :: {tag() | nil, t()}
  def cancel(%__MODULE__{} = relay, id) do
    {tag, pending} = Map.pop(relay.pending, id)
    {tag, %{relay | pending: pending}}
  end

  @doc "Every pending call's tag, none pending after."
  @spec take_pending(t()) :: {[tag()], t()}
  def take_pending(%__MODULE__{} = relay),
    do: {relay.pending |> Enum.sort() |> Enum.map(&elem(&1, 1)), %{relay | pending: %{}}}

  @doc "How many calls are pending."
  @spec pending_count(t()) :: non_neg_integer()
  def pending_count(%__MODULE__{pending: pending}), do: map_size(pending)

  @doc "How many stdout messages were neither an answer nor the backend's own."
  @spec dropped(t()) :: non_neg_integer()
  def dropped(%__MODULE__{dropped: dropped}), do: dropped

  # ————— bytes in —————

  @doc "An attach connection's bytes: the events their stdout frames carry."
  @spec frames(t(), binary()) ::
          {:ok, [event()], t()} | {:error, :relay_protocol | :frame_too_large}
  def frames(%__MODULE__{} = relay, data) when is_binary(data) do
    case KeeperProtocol.parse_frames(relay.frames <> data) do
      {:ok, frames, rest} -> each_frame(%{relay | frames: rest}, frames, [])
      {:error, _reason} -> {:error, :relay_protocol}
    end
  end

  defp each_frame(relay, [], events), do: {:ok, events, relay}

  defp each_frame(relay, [{:stdout, payload} | frames], events) do
    case stdout(relay, payload) do
      {:ok, more, relay} -> each_frame(relay, frames, events ++ more)
      {:error, _reason} = error -> error
    end
  end

  defp each_frame(relay, [{:stderr, payload} | frames], events),
    do: each_frame(stderr(relay, payload), frames, events)

  defp each_frame(_relay, _frames, _events), do: {:error, :relay_protocol}

  @doc "Bytes of the backend's stdout: the events of every line they complete."
  @spec stdout(t(), binary()) :: {:ok, [event()], t()} | {:error, :frame_too_large}
  def stdout(%__MODULE__{} = relay, data) when is_binary(data) do
    case :binary.match(data, "\n") do
      :nomatch -> partial(relay, relay.line <> data)
      _found -> lines(relay, data)
    end
  end

  # No newline yet: the line grows, within its bound.
  defp partial(relay, line) do
    if byte_size(line) > relay.max_frame_bytes,
      do: {:error, :frame_too_large},
      else: {:ok, [], %{relay | line: line}}
  end

  defp lines(relay, data) do
    [partial | lines] = (relay.line <> data) |> :binary.split("\n", [:global]) |> Enum.reverse()
    lines = Enum.reverse(lines)

    if Enum.any?([partial | lines], &(byte_size(&1) > relay.max_frame_bytes)) do
      {:error, :frame_too_large}
    else
      {events, relay} = Enum.reduce(lines, {[], %{relay | line: partial}}, &on_line/2)
      {:ok, Enum.reverse(events), relay}
    end
  end

  defp on_line(line, {events, relay}) do
    case line |> String.trim() |> decode() do
      :blank -> {events, relay}
      {:ok, message} -> classify(message, events, relay)
      :error -> {events, drop(relay)}
    end
  end

  defp decode(""), do: :blank

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, %{} = message} -> {:ok, message}
      _ -> :error
    end
  end

  # The backend's own request or notification: its ids are its own.
  defp classify(%{"method" => method} = message, events, relay),
    do: {[{:child, message["id"], child_method(method)} | events], relay}

  defp classify(%{"id" => id} = message, events, relay) when id != nil do
    with {:ok, outcome} <- outcome(message),
         {:ok, key} <- pending_key(relay.pending, id) do
      {tag, pending} = Map.pop(relay.pending, key)
      {[{:answer, tag, outcome} | events], %{relay | pending: pending}}
    else
      :error -> {events, drop(relay)}
    end
  end

  defp classify(_message, events, relay), do: {events, drop(relay)}

  defp child_method(method) when is_binary(method), do: method
  defp child_method(_method), do: ""

  defp outcome(%{"error" => error}) when error != nil, do: {:ok, {:error, error}}
  defp outcome(%{"result" => result}), do: {:ok, {:result, result}}
  defp outcome(_message), do: :error

  # The id as minted, or a number or a string spelling it.
  defp pending_key(pending, id) when is_integer(id) and is_map_key(pending, id), do: {:ok, id}

  defp pending_key(pending, id) when is_float(id) do
    key = trunc(id)
    if key == id and is_map_key(pending, key), do: {:ok, key}, else: :error
  end

  defp pending_key(pending, id) when is_binary(id) do
    case number(String.trim(id)) do
      {:ok, number} -> pending_key(pending, number)
      :error -> :error
    end
  end

  defp pending_key(_pending, _id), do: :error

  defp number(""), do: :error

  defp number(text) do
    case Integer.parse(text) do
      {integer, ""} ->
        {:ok, integer}

      _ ->
        case Float.parse(text) do
          {float, ""} -> {:ok, float}
          _ -> :error
        end
    end
  end

  defp drop(relay), do: %{relay | dropped: relay.dropped + 1}

  @doc "Bytes of the backend's stderr, of which the tail and its slack are kept."
  @spec stderr(t(), binary()) :: t()
  def stderr(%__MODULE__{} = relay, data) when is_binary(data) do
    kept = relay.stderr <> data
    keep = relay.tail_bytes + relay.slack_bytes

    if byte_size(kept) > keep,
      do: %{relay | stderr: binary_part(kept, byte_size(kept) - keep, keep)},
      else: %{relay | stderr: kept}
  end

  @doc """
  The stderr a status reports: what is kept, masked with `secrets` as
  `Prima.LocusBackends.mask/2` does, then cut to its last
  `stderr_tail_bytes` bytes, as text.
  """
  @spec stderr_tail(t(), [String.t()]) :: String.t()
  def stderr_tail(%__MODULE__{} = relay, secrets) when is_list(secrets) do
    masked = LocusBackends.mask(relay.stderr, secrets)
    size = byte_size(masked)

    masked
    |> binary_part(max(size - relay.tail_bytes, 0), min(size, relay.tail_bytes))
    |> String.replace_invalid()
  end
end
