# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends.Relay do
  @moduledoc """
  The stdio of one session's process, as data: the sequence-numbered
  buffer of the lines its stdout writes and the tail of its stderr. State
  in, state out; no process, and no protocol: what the lines mean is the
  owner's.

  Stdout is split on newlines; a line's trailing carriage return is
  dropped (a pseudo-terminal ends its lines with one), and its bytes that
  are not UTF-8 are replaced, so every line is text. A line, or the part
  of one that has no newline yet, longer than
  `Prima.LocusBackends.max_line_bytes/0` is `:line_too_long`, and the
  session's process is killed for it. `flush/1` makes the part with no
  newline a line of its own, as a session on a pseudo-terminal does with a
  prompt that waits for its answer.

  Each line is numbered from 1. The buffer keeps a line until `take/4`
  names an `after` at or above its number, and holds at most
  `Prima.LocusBackends.max_buffer_bytes/0` bytes of lines: past that the
  oldest are dropped and counted. `take/4` answers the lines past `after`
  that fit its byte budget (one at least) and how many lines between
  `after` and the first it answers were dropped; asked twice with the same
  `after`, it answers the same lines, so a lost answer is replayed.

  Stderr is never parsed: the last `Prima.LocusBackends.stderr_tail_bytes/0`
  bytes are what a status reports, and `stderr_tail_slack_bytes/0` more
  are kept so a credential split by the cut is masked before the cut is
  taken (`stderr_tail/2`).
  """

  alias Prima.LocusBackends

  defstruct partial: "",
            lines: :queue.new(),
            bytes: 0,
            next_seq: 1,
            dropped: 0,
            stderr: "",
            max_line_bytes: nil,
            max_buffer_bytes: nil,
            tail_bytes: nil,
            slack_bytes: nil

  @type t :: %__MODULE__{
          partial: binary(),
          lines: :queue.queue({pos_integer(), String.t()}),
          bytes: non_neg_integer(),
          next_seq: pos_integer(),
          dropped: non_neg_integer(),
          stderr: binary(),
          max_line_bytes: pos_integer(),
          max_buffer_bytes: pos_integer(),
          tail_bytes: pos_integer(),
          slack_bytes: non_neg_integer()
        }

  # A line's share of an answer beyond its text: its sequence number and
  # the members around them.
  @line_overhead 32

  @doc """
  A relay with no bytes seen. Options, each defaulting to
  `Prima.LocusBackends`' bound of the same name: `:max_line_bytes`,
  `:max_buffer_bytes`, `:stderr_tail_bytes`, `:stderr_tail_slack_bytes`.
  """
  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = Map.new(opts)

    %__MODULE__{
      max_line_bytes: Map.get(opts, :max_line_bytes, LocusBackends.max_line_bytes()),
      max_buffer_bytes: Map.get(opts, :max_buffer_bytes, LocusBackends.max_buffer_bytes()),
      tail_bytes: Map.get(opts, :stderr_tail_bytes, LocusBackends.stderr_tail_bytes()),
      slack_bytes:
        Map.get(opts, :stderr_tail_slack_bytes, LocusBackends.stderr_tail_slack_bytes())
    }
  end

  # ————— stdout —————

  @doc "Bytes of the process's stdout: every line they complete is buffered."
  @spec stdout(t(), binary()) :: {:ok, t()} | {:error, :line_too_long}
  def stdout(%__MODULE__{} = relay, data) when is_binary(data) do
    [partial | complete] =
      (relay.partial <> data) |> :binary.split("\n", [:global]) |> Enum.reverse()

    if Enum.any?([partial | complete], &(byte_size(&1) > relay.max_line_bytes)) do
      {:error, :line_too_long}
    else
      relay =
        complete |> Enum.reverse() |> Enum.reduce(%{relay | partial: partial}, &push(&2, &1))

      {:ok, relay}
    end
  end

  @doc "Whether part of a line waits for its newline."
  @spec partial?(t()) :: boolean()
  def partial?(%__MODULE__{partial: partial}), do: partial != ""

  @doc "The part of a line with no newline yet, made a line of its own."
  @spec flush(t()) :: t()
  def flush(%__MODULE__{partial: ""} = relay), do: relay
  def flush(%__MODULE__{} = relay), do: push(%{relay | partial: ""}, relay.partial)

  defp push(relay, raw) do
    text = raw |> String.trim_trailing("\r") |> String.replace_invalid()
    seq = relay.next_seq

    %{
      relay
      | lines: :queue.in({seq, text}, relay.lines),
        bytes: relay.bytes + byte_size(text),
        next_seq: seq + 1
    }
    |> bound()
  end

  # The oldest lines go, counted, until the buffer is within its bound.
  defp bound(%{bytes: bytes, max_buffer_bytes: max} = relay) when bytes <= max, do: relay

  defp bound(relay) do
    {{:value, {_seq, text}}, lines} = :queue.out(relay.lines)

    bound(%{
      relay
      | lines: lines,
        bytes: relay.bytes - byte_size(text),
        dropped: relay.dropped + 1
    })
  end

  @doc "How many lines the buffer dropped for its bound."
  @spec dropped(t()) :: non_neg_integer()
  def dropped(%__MODULE__{dropped: dropped}), do: dropped

  @doc "Whether a line past `after` is buffered."
  @spec past?(t(), non_neg_integer()) :: boolean()
  def past?(%__MODULE__{} = relay, after_seq) do
    case :queue.peek_r(relay.lines) do
      {:value, {seq, _text}} -> seq > after_seq
      :empty -> false
    end
  end

  @doc """
  Every line at or below `after` let go, then the lines past it that fit
  `budget` bytes of an answer (the first always), each `%{seq, text}`, and
  how many lines between `after` and the first of them were dropped.
  """
  @spec take(t(), non_neg_integer(), pos_integer()) ::
          {[LocusBackends.line()], non_neg_integer(), t()}
  def take(%__MODULE__{} = relay, after_seq, budget) do
    relay = acknowledge(relay, after_seq)

    first =
      case :queue.peek(relay.lines) do
        {:value, {seq, _text}} -> seq
        :empty -> relay.next_seq
      end

    lines = collect(:queue.to_list(relay.lines), budget, [])
    {lines, max(first - after_seq - 1, 0), relay}
  end

  defp acknowledge(relay, after_seq) do
    case :queue.peek(relay.lines) do
      {:value, {seq, text}} when seq <= after_seq ->
        relay
        |> Map.merge(%{lines: :queue.drop(relay.lines), bytes: relay.bytes - byte_size(text)})
        |> acknowledge(after_seq)

      _ ->
        relay
    end
  end

  defp collect([], _budget, taken), do: Enum.reverse(taken)

  defp collect([{seq, text} | rest], budget, taken) do
    cost = byte_size(Jason.encode!(text)) + @line_overhead

    if taken != [] and cost > budget,
      do: Enum.reverse(taken),
      else: collect(rest, budget - cost, [%{seq: seq, text: text} | taken])
  end

  # ————— stderr —————

  @doc "Bytes of the process's stderr, of which the tail and its slack are kept."
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
