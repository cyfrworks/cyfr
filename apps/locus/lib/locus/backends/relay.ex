# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends.Relay do
  @moduledoc """
  The stdio of one session's process, as data: the sequence-numbered
  buffer of what its stdout writes and the tail of its stderr. State in,
  state out; no process, and no protocol: what the bytes mean is the
  owner's.

  A relay of mode `:run` buffers lines. Stdout is split on newlines, a
  line's trailing carriage return is dropped, its bytes that are not
  UTF-8 are replaced, so every line is text, and it is masked with the
  relay's `:secrets` as `Prima.LocusBackends.mask/2` masks, so what is
  buffered is what is answered.
  A line, or the part of one that has no newline yet, longer than
  `Prima.LocusBackends.max_line_bytes/0` is `:line_too_long`, and the
  session's process is killed for it. `flush/1` makes the part with no
  newline a line of its own, once the process is gone.

  A relay of mode `:terminal` buffers chunks: what `output/2` is given,
  already masked, in pieces of at most
  `Prima.LocusBackends.max_chunk_bytes/0` bytes, as they are.

  Each line or chunk is numbered from 1. The buffer keeps one until
  `take/3` names an `after` at or above its number, and holds at most
  `Prima.LocusBackends.max_buffer_bytes/0` bytes of them, each charged its
  bytes and `line_charge_bytes/0` of framing (`bytes`), and at most
  `max_buffer_lines/0` of them: past either the oldest are dropped and
  counted, so empty lines cannot grow it without end. `drop_to/2` drops
  the oldest alike, counted, for a bound beyond the relay's own.

  Each line or chunk also costs an answer what it is encoded as there: a
  line its text as JSON escapes it, a chunk its bytes in base64, and 32
  bytes for its number and the members around them, reckoned once, as it
  is buffered. `cost/3` is what an answer past `after` within a budget
  costs, the first counted whatever it costs, so that budget can be asked
  for before anything is taken; `take/3` answers those past `after` that
  fit its budget, never more, and how many between `after` and the first
  past it were dropped. Asked twice with the same `after`, it answers the
  same ones, so a lost answer is replayed.

  Stderr is never parsed: the last `Prima.LocusBackends.stderr_tail_bytes/0`
  bytes are what a status reports for a scratch program, and
  `stderr_tail_slack_bytes/0` more are kept so a credential split by the
  cut is masked before the cut is taken (`stderr_tail/2`), copied to
  their own size. Every byte is counted (`stderr_bytes/1`), which is all a
  kept program's status names. What the relay holds, its buffer and the
  stderr it keeps, is `held/1`.
  """

  alias Prima.LocusBackends

  # `lines` is made by `new/1`: a queue is opaque, so no struct literal
  # holds one.
  defstruct mode: :run,
            secrets: [],
            partial: "",
            lines: nil,
            count: 0,
            bytes: 0,
            next_seq: 1,
            dropped: 0,
            stderr: "",
            stderr_bytes: 0,
            max_line_bytes: nil,
            max_buffer_bytes: nil,
            max_buffer_lines: nil,
            charge: nil,
            tail_bytes: nil,
            slack_bytes: nil

  @type t :: %__MODULE__{
          mode: :run | :terminal,
          secrets: [String.t()],
          partial: binary(),
          lines: :queue.queue({pos_integer(), binary(), pos_integer()}),
          count: non_neg_integer(),
          bytes: non_neg_integer(),
          next_seq: pos_integer(),
          dropped: non_neg_integer(),
          stderr: binary(),
          stderr_bytes: non_neg_integer(),
          max_line_bytes: pos_integer(),
          max_buffer_bytes: pos_integer(),
          max_buffer_lines: pos_integer(),
          charge: pos_integer(),
          tail_bytes: pos_integer(),
          slack_bytes: non_neg_integer()
        }

  # A line's share of an answer beyond its text: its sequence number and
  # the members around them.
  @line_overhead 32

  @doc """
  A relay with no bytes seen, of `:mode` `:run` (the default) or
  `:terminal`, masking a run's lines with `:secrets` (none). Other
  options, each defaulting to `Prima.LocusBackends`' bound of the same
  name: `:max_line_bytes`, `:max_buffer_bytes`, `:max_buffer_lines`,
  `:line_charge_bytes`, `:stderr_tail_bytes`, `:stderr_tail_slack_bytes`.
  """
  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = Map.new(opts)

    %__MODULE__{
      mode: Map.get(opts, :mode, :run),
      secrets: Map.get(opts, :secrets, []),
      lines: :queue.new(),
      max_line_bytes: Map.get(opts, :max_line_bytes, LocusBackends.max_line_bytes()),
      max_buffer_bytes: Map.get(opts, :max_buffer_bytes, LocusBackends.max_buffer_bytes()),
      max_buffer_lines: Map.get(opts, :max_buffer_lines, LocusBackends.max_buffer_lines()),
      charge: Map.get(opts, :line_charge_bytes, LocusBackends.line_charge_bytes()),
      tail_bytes: Map.get(opts, :stderr_tail_bytes, LocusBackends.stderr_tail_bytes()),
      slack_bytes:
        Map.get(opts, :stderr_tail_slack_bytes, LocusBackends.stderr_tail_slack_bytes())
    }
  end

  # ————— stdout —————

  @doc "Bytes of a run's stdout: every line they complete is buffered."
  @spec stdout(t(), binary()) :: {:ok, t()} | {:error, :line_too_long}
  def stdout(%__MODULE__{mode: :run} = relay, data) when is_binary(data) do
    # Only the part line left by the last write is joined, to its rest:
    # every other line is read where it came, never copied.
    [first | rest] = :binary.split(data, "\n", [:global])
    [partial | complete] = Enum.reverse([joined(relay.partial, first) | rest])

    if Enum.any?([partial | complete], &(byte_size(&1) > relay.max_line_bytes)) do
      {:error, :line_too_long}
    else
      relay =
        complete |> Enum.reverse() |> Enum.reduce(%{relay | partial: partial}, &push(&2, &1))

      {:ok, relay}
    end
  end

  defp joined("", first), do: first
  defp joined(partial, first), do: partial <> first

  @doc "The part of a line with no newline yet, made a line of its own."
  @spec flush(t()) :: t()
  def flush(%__MODULE__{partial: ""} = relay), do: relay
  def flush(%__MODULE__{} = relay), do: push(%{relay | partial: ""}, relay.partial)

  @doc "Bytes of a terminal's output, masked already, buffered as chunks of at most the bound."
  @spec output(t(), binary()) :: t()
  def output(%__MODULE__{mode: :terminal} = relay, ""), do: relay

  def output(%__MODULE__{mode: :terminal} = relay, data) when is_binary(data) do
    max = LocusBackends.max_chunk_bytes()

    if byte_size(data) > max do
      <<chunk::binary-size(^max), rest::binary>> = data
      relay |> append(chunk) |> output(rest)
    else
      append(relay, data)
    end
  end

  defp push(relay, raw) do
    text =
      raw
      |> String.trim_trailing("\r")
      |> String.replace_invalid()
      |> LocusBackends.mask(relay.secrets)

    append(relay, text)
  end

  defp append(relay, data) do
    seq = relay.next_seq

    %{
      relay
      | lines: :queue.in({seq, data, entry_cost(relay.mode, data)}, relay.lines),
        count: relay.count + 1,
        bytes: relay.bytes + charge(relay, data),
        next_seq: seq + 1
    }
    |> bound()
  end

  # What a line costs the buffer: its text and its framing.
  defp charge(relay, text), do: byte_size(text) + relay.charge

  # The oldest lines go, counted, until the buffer is within both bounds.
  defp bound(%{bytes: bytes, count: count} = relay)
       when bytes <= relay.max_buffer_bytes and count <= relay.max_buffer_lines,
       do: relay

  defp bound(relay), do: relay |> drop_oldest() |> bound()

  @doc """
  What the relay holds for its session: the buffer's `bytes` and the
  stderr kept, which a session names to the role's count.
  """
  @spec held(t()) :: non_neg_integer()
  def held(%__MODULE__{bytes: bytes, stderr: stderr}) when is_integer(bytes),
    do: bytes + byte_size(stderr)

  @doc """
  The oldest lines or chunks dropped, each counted as the buffer's own
  bound counts it, until the relay holds at most `bytes` (`held/1`); with
  none left, the stderr kept is cut to its last bytes that fit.
  """
  @spec drop_to(t(), non_neg_integer()) :: t()
  def drop_to(%__MODULE__{} = relay, bytes) do
    cond do
      held(relay) <= bytes -> relay
      relay.count > 0 -> relay |> drop_oldest() |> drop_to(bytes)
      true -> %{relay | stderr: last(relay.stderr, max(bytes - relay.bytes, 0))}
    end
  end

  defp drop_oldest(relay) do
    {{:value, {_seq, data, _cost}}, lines} = :queue.out(relay.lines)

    %{
      relay
      | lines: lines,
        count: relay.count - 1,
        bytes: relay.bytes - charge(relay, data),
        dropped: relay.dropped + 1
    }
  end

  @doc "How many lines the buffer dropped for its bound."
  @spec dropped(t()) :: non_neg_integer()
  def dropped(%__MODULE__{dropped: dropped}), do: dropped

  @doc "Whether a line or a chunk past `after` is buffered."
  @spec past?(t(), non_neg_integer()) :: boolean()
  def past?(%__MODULE__{} = relay, after_seq) do
    case :queue.peek_r(relay.lines) do
      {:value, {seq, _data, _cost}} -> seq > after_seq
      :empty -> false
    end
  end

  @doc """
  What an answer of the lines or chunks past `after` costs: as many as
  fit `budget`, the first whatever it costs, which `take/3` given that
  cost answers exactly. 0 when none is past `after`. Nothing is taken,
  let go or copied.
  """
  @spec cost(t(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def cost(%__MODULE__{} = relay, after_seq, budget) do
    relay.lines
    |> :queue.to_list()
    |> Enum.drop_while(fn {seq, _data, _cost} -> seq <= after_seq end)
    |> fit(budget, 0)
  end

  defp fit([], _budget, total), do: total

  # Integers by construction: what the opaque queue holds is unknown to
  # Dialyzer, and a sum of unknowns may be a float.
  defp fit([{_seq, _data, cost} | rest], budget, total)
       when is_integer(cost) and is_integer(budget) do
    if total > 0 and total + cost > budget,
      do: total,
      else: fit(rest, budget, total + cost)
  end

  @doc """
  Every line or chunk at or below `after` let go, then those past it whose
  cost together fits `budget` bytes of an answer, none past it, each
  `%{seq, text}` of a run or `%{seq, bytes}` of a terminal, and how many
  between `after` and the first past it were dropped.
  """
  @spec take(t(), non_neg_integer(), non_neg_integer()) ::
          {[LocusBackends.line() | LocusBackends.chunk()], non_neg_integer(), t()}
  def take(%__MODULE__{} = relay, after_seq, budget) do
    relay = acknowledge(relay, after_seq)

    first =
      case :queue.peek(relay.lines) do
        {:value, {seq, _data, _cost}} -> seq
        :empty -> relay.next_seq
      end

    lines = collect(relay.mode, :queue.to_list(relay.lines), budget, [])
    {lines, max(first - after_seq - 1, 0), relay}
  end

  defp acknowledge(relay, after_seq) do
    case :queue.peek(relay.lines) do
      {:value, {seq, data, _cost}} when seq <= after_seq ->
        relay
        |> Map.merge(%{
          lines: :queue.drop(relay.lines),
          count: relay.count - 1,
          bytes: relay.bytes - charge(relay, data)
        })
        |> acknowledge(after_seq)

      _ ->
        relay
    end
  end

  defp collect(_mode, [], _budget, taken), do: Enum.reverse(taken)

  defp collect(mode, [{seq, data, cost} | rest], budget, taken) do
    if cost > budget,
      do: Enum.reverse(taken),
      else: collect(mode, rest, budget - cost, [entry(mode, seq, data) | taken])
  end

  # What an entry costs an answer: a line as JSON escapes it, a chunk in
  # base64, and its share beside them.
  defp entry_cost(:run, text), do: json_bytes(text, 2) + @line_overhead
  defp entry_cost(:terminal, bytes), do: div(byte_size(bytes) + 2, 3) * 4 + @line_overhead

  # A string's bytes as JSON writes it, quoted (Jason's `escape: :json`):
  # a quote, a backslash and the control bytes with a short escape take
  # two, every other byte below 0x20 six (`\u00XX`), any other byte one.
  # Read a byte at a time, so nothing of the text is copied.
  defp json_bytes(<<byte, rest::binary>>, n) when byte in ~c"\"\\\b\t\n\f\r",
    do: json_bytes(rest, n + 2)

  defp json_bytes(<<byte, rest::binary>>, n) when byte < 0x20, do: json_bytes(rest, n + 6)
  defp json_bytes(<<_byte, rest::binary>>, n), do: json_bytes(rest, n + 1)
  defp json_bytes(<<>>, n), do: n

  defp entry(:run, seq, text), do: %{seq: seq, text: text}
  defp entry(:terminal, seq, bytes), do: %{seq: seq, bytes: bytes}

  # ————— stderr —————

  @doc "Bytes of the process's stderr, of which the tail and its slack are kept."
  @spec stderr(t(), binary()) :: t()
  def stderr(%__MODULE__{} = relay, data) when is_binary(data) do
    kept = last(relay.stderr <> data, relay.tail_bytes + relay.slack_bytes)
    %{relay | stderr: kept, stderr_bytes: relay.stderr_bytes + byte_size(data)}
  end

  # The last `keep` bytes of `bytes`, copied to their own size: a part of
  # a larger binary, or of one an append grew beyond its bytes, would hold
  # the whole of it alive.
  defp last(bytes, keep) do
    size = byte_size(bytes)
    :binary.copy(binary_part(bytes, max(size - keep, 0), min(size, keep)))
  end

  @doc "How many bytes of stderr the process wrote, all a kept program's status names."
  @spec stderr_bytes(t()) :: non_neg_integer()
  def stderr_bytes(%__MODULE__{stderr_bytes: bytes}), do: bytes

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
