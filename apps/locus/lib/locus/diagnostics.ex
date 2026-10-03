# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Diagnostics do
  @moduledoc """
  A build's log as the build wire carries it (`Prima.BuilderProtocol`): the
  progress lines a build's answer streams, and the same lines as the
  `diagnostics` of its terminal line, each `stage: message`.

  The build writes the log, so nothing about it is trusted: bytes that are
  not UTF-8 are replaced, a line longer than the wire's line bound goes
  out in pieces cut between characters, and the whole is held to the
  wire's log bound by a budget (`budget/0`) charged where the lines are
  produced, in the process running the build. A line is charged as the
  bytes that leave the service for it: its whole encoded progress line,
  envelope, stage, escaped message and newline. The terminal line carries
  the same lines again as JSON strings, each shorter than the progress line
  it was charged as, so the answer stays within
  `Prima.BuilderProtocol.max_answer_bytes/0`. A build that writes without
  end therefore costs the builder one log's worth of memory, and the
  answer still encodes. Past the budget a build's own lines are dropped
  whole behind one line saying so; the few lines the builder writes itself
  (the stages, why an output was refused) keep a reserve, so a failure is
  still explained at the end of a loud build.
  """

  alias Prima.BuilderProtocol

  # The longest `stage: ` a line is prefixed with.
  @prefix_bytes BuilderProtocol.stages()
                |> Enum.map(&(byte_size(Atom.to_string(&1)) + 2))
                |> Enum.max()
  @message_bytes BuilderProtocol.max_line_bytes() - @prefix_bytes
  # What the build's own lines leave of the log: room for the line saying
  # the log was cut, itself charged as its encoded line, and for the
  # builder's few lines after it.
  @reserve_bytes 16_384
  @output_bytes BuilderProtocol.max_log_bytes() - @reserve_bytes
  @cut_message "the build's log passed #{@output_bytes} bytes; the rest of it is not kept"

  @typedoc "What a run's lines are charged to: bytes admitted, and whether the log was cut."
  @opaque budget :: :counters.counters_ref()

  @doc "A fresh budget: one build's log."
  @spec budget() :: budget()
  def budget, do: :counters.new(2, [])

  @typedoc """
  One admitted line: its progress line as the wire carries it, without the
  newline, and the same line as a JSON string for the terminal line's
  diagnostics (`Prima.BuilderProtocol.encode_diagnostic/1`).
  """
  @type admitted :: {progress :: String.t(), diagnostic :: String.t()}

  @doc """
  The lines `message` makes at `stage` within what is left of `budget`,
  each encoded and charged as its progress line with its newline: none for
  an empty message or a spent budget, several for a long one.
  """
  @spec admit(budget(), BuilderProtocol.stage(), String.t()) :: [admitted()]
  def admit(budget, stage, message) when is_atom(stage) and is_binary(message) do
    message
    |> String.replace_invalid()
    |> pieces()
    |> Enum.flat_map(&charge(budget, stage, &1))
  end

  @doc "The diagnostics line of a progress line."
  @spec line(BuilderProtocol.stage(), String.t()) :: String.t()
  def line(stage, message), do: "#{stage}: #{message}"

  @doc """
  `text` as a refusal's sentence: valid UTF-8 within the wire's line bound,
  cut between characters, and never empty.
  """
  @spec sentence(String.t()) :: String.t()
  def sentence(text) when is_binary(text) do
    case text |> String.replace_invalid() |> head(BuilderProtocol.max_line_bytes()) do
      {"", _rest} -> "the request was refused"
      {sentence, _rest} -> sentence
    end
  end

  defp charge(budget, stage, message) do
    limit = if stage == :output, do: @output_bytes, else: BuilderProtocol.max_log_bytes()

    # Once the build's log is cut it stays cut: a short line that would
    # fit again never follows the line saying the rest is not kept.
    if stage == :output and :counters.get(budget, 2) == 1 do
      []
    else
      {progress, _diagnostic} = admitted = encode(stage, message)

      cond do
        within?(budget, progress, limit) ->
          [admitted]

        stage == :output ->
          :counters.add(budget, 2, 1)
          cut(budget)

        true ->
          []
      end
    end
  end

  # Said once, from the reserve, when the first line is dropped; a budget
  # already spent past the reserve says nothing, so the log's bound holds
  # whatever was admitted before.
  defp cut(budget) do
    {progress, _diagnostic} = admitted = encode(:output, @cut_message)
    if within?(budget, progress, BuilderProtocol.max_log_bytes()), do: [admitted], else: []
  end

  # Charges the line with its newline when it fits under `limit`.
  defp within?(budget, progress, limit) do
    cost = byte_size(progress) + 1

    if :counters.get(budget, 1) + cost <= limit do
      :counters.add(budget, 1, cost)
      true
    else
      false
    end
  end

  # A piece is valid UTF-8 within the line bound, so both encode.
  defp encode(stage, message) do
    {:ok, progress} = BuilderProtocol.encode_progress(stage, message)
    {:ok, diagnostic} = BuilderProtocol.encode_diagnostic(line(stage, message))
    {progress, diagnostic}
  end

  defp pieces(""), do: []

  defp pieces(message) do
    {piece, rest} = head(message, @message_bytes)
    [piece | pieces(rest)]
  end

  # The longest head of valid UTF-8 `text` within `max` bytes that ends
  # between characters, and what follows it.
  defp head(text, max) when byte_size(text) <= max, do: {text, ""}

  defp head(text, max) do
    size = boundary(text, max)
    <<head::binary-size(^size), rest::binary>> = text
    {head, rest}
  end

  # A continuation byte (0b10xxxxxx) at `size` means a character straddles
  # the cut: step back to its first byte, at most three times.
  defp boundary(text, size) do
    case :binary.at(text, size) do
      byte when Bitwise.band(byte, 0xC0) == 0x80 and size > 0 -> boundary(text, size - 1)
      _ -> size
    end
  end
end
