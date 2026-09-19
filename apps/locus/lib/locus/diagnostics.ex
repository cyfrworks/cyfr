# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Diagnostics do
  @moduledoc """
  A build's log as the build wire carries it (`Cyfr.BuilderProtocol`): the
  progress lines a build's answer streams, and the same lines as the
  `diagnostics` of its terminal line, each `stage: message`.

  The build writes the log, so nothing about it is trusted: bytes that are
  not UTF-8 are replaced, a line longer than the wire's line bound goes
  out in pieces cut between characters, and the whole is held to the
  wire's log bound by a budget (`budget/0`) charged where the lines are
  produced, in the process running the build. A build that writes without
  end therefore costs the builder one log's worth of memory, and the
  answer still encodes. Past the budget a build's own lines are dropped
  behind one line saying so; the few lines the builder writes itself (the
  stages, why an output was refused) keep a reserve, so a failure is still
  explained at the end of a loud build.
  """

  alias Cyfr.BuilderProtocol

  # The longest `stage: ` a line is prefixed with.
  @prefix_bytes BuilderProtocol.stages()
                |> Enum.map(&(byte_size(Atom.to_string(&1)) + 2))
                |> Enum.max()
  @message_bytes BuilderProtocol.max_line_bytes() - @prefix_bytes
  @reserve_bytes 16_384
  @output_bytes BuilderProtocol.max_log_bytes() - @reserve_bytes

  @typedoc "What a run's lines are charged to: bytes admitted, and whether the log was cut."
  @opaque budget :: :counters.counters_ref()

  @doc "A fresh budget: one build's log."
  @spec budget() :: budget()
  def budget, do: :counters.new(2, [])

  @doc """
  The lines `message` makes at `stage` within what is left of `budget`, as
  `{stage, message}` pairs ready for `Cyfr.BuilderProtocol.encode_progress/2`:
  none for an empty message or a spent budget, several for a long one.
  """
  @spec admit(budget(), BuilderProtocol.stage(), String.t()) ::
          [{BuilderProtocol.stage(), String.t()}]
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
    cost = byte_size(line(stage, message)) + 1
    limit = if stage == :output, do: @output_bytes, else: BuilderProtocol.max_log_bytes()

    cond do
      # Once the build's log is cut it stays cut: a short line that would
      # fit again never follows the line saying the rest is not kept.
      stage == :output and :counters.get(budget, 2) == 1 ->
        []

      :counters.get(budget, 1) + cost <= limit ->
        :counters.add(budget, 1, cost)
        [{stage, message}]

      stage == :output ->
        :counters.add(budget, 2, 1)
        cut(budget)

      true ->
        []
    end
  end

  # Said once, from the reserve, when the first line is dropped.
  defp cut(budget) do
    message = "the build's log passed #{@output_bytes} bytes; the rest of it is not kept"
    :counters.add(budget, 1, byte_size(line(:output, message)) + 1)
    [{:output, message}]
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
