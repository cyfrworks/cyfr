# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.JsonFormatter do
  @moduledoc """
  JSON log formatter for structured logging in production.

  Activated by setting `CYFR_LOG_FORMAT=json` in the environment.
  Outputs one JSON object per log line with standard fields for
  log aggregators (Datadog, Splunk, ELK, Loki).
  """

  @doc """
  Format a log event as a single-line JSON string.

  Conforms to the `:logger` formatter callback signature.
  """
  @spec format(Logger.level(), Logger.message(), Logger.Formatter.time(), keyword()) :: iodata()
  def format(level, message, {date, time}, metadata) do
    timestamp = format_timestamp(date, time)
    msg = IO.iodata_to_binary(message)

    base = %{
      "timestamp" => timestamp,
      "level" => to_string(level),
      "message" => msg
    }

    fields =
      metadata
      |> Keyword.take([
        :request_id,
        :user_id,
        :org_id,
        :project_id,
        :auth_method,
        :module,
        :function,
        :line
      ])
      |> Enum.reduce(base, fn {k, v}, acc ->
        Map.put(acc, to_string(k), to_string(v))
      end)

    case Jason.encode_to_iodata(fields) do
      {:ok, data} -> [data, ?\n]
      {:error, _} -> "#{inspect({date, time})} [#{level}] #{message}\n"
    end
  end

  defp format_timestamp({year, month, day}, {hour, min, sec, _usec}) do
    :io_lib.format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [
      year,
      month,
      day,
      hour,
      min,
      sec
    ])
    |> IO.iodata_to_binary()
  end
end