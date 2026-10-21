# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Test.EventStream do
  @moduledoc """
  A `text/event-stream` body read back as its events, so a test can
  assert on what `Prima.TinctureWire`'s stream encoders wrote.
  """

  @typedoc "One event of a stream, read back: its id, its name and its data."
  @type event :: %{id: non_neg_integer() | nil, event: String.t(), data: term()}

  @doc """
  The events of a `text/event-stream` body read back, in order: each
  group of lines ended by a blank line, `id` a number or nil, `event`
  its name (`"message"` when it names none) and `data` its JSON (data
  lines joined with a newline). A comment line (`:`) and any other field
  are skipped, an event not ended by its blank line is incomplete, and an
  event with no data or data that is not JSON is dropped, as the SDK's
  reader drops it.
  """
  @spec decode(String.t()) :: [event()]
  def decode(body) when is_binary(body) do
    body
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.chunk_while(
      [],
      fn
        "", acc -> {:cont, Enum.reverse(acc), []}
        line, acc -> {:cont, [line | acc]}
      end,
      fn _incomplete -> {:cont, []} end
    )
    |> Enum.flat_map(&stream_group/1)
  end

  defp stream_group(lines) do
    event =
      Enum.reduce(lines, %{id: nil, event: "message", data: []}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          ["", _comment] -> acc
          [field, value] -> stream_field(acc, field, String.replace_prefix(value, " ", ""))
          [field] -> stream_field(acc, field, "")
        end
      end)

    with [_ | _] = data <- event.data,
         {:ok, decoded} <- Jason.decode(data |> Enum.reverse() |> Enum.join("\n")) do
      [%{id: event.id, event: event.event, data: decoded}]
    else
      _ -> []
    end
  end

  defp stream_field(acc, "data", value), do: %{acc | data: [value | acc.data]}
  defp stream_field(acc, "event", value), do: %{acc | event: value}

  defp stream_field(acc, "id", value) do
    case Integer.parse(value) do
      {id, ""} when id >= 0 -> %{acc | id: id}
      _ -> %{acc | id: nil}
    end
  end

  defp stream_field(acc, _field, _value), do: acc
end
