# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.JsonFormatter do
  @moduledoc """
  JSON log formatter for structured logging in production.

  Activated by setting `CYFR_LOG_FORMAT=json` in the environment.
  Outputs one JSON object per log line with standard fields for
  log aggregators (Datadog, Splunk, ELK, Loki).

  Which metadata keys are emitted comes from the configured
  `:logger, :default_formatter` roster — the same one the plain-text
  formatter reads — so adding a key is one edit, in config.
  """

  # Resolved once and cached: this runs on every log line, and on a busy
  # server that is the hottest read in the system. `:persistent_term` is
  # written exactly once per node, which is what it is for.
  @roster_key {__MODULE__, :metadata_keys}

  @doc """
  Format a log event as a single-line JSON string.

  Conforms to the `:logger` formatter callback signature.
  """
  @spec format(Logger.level(), Logger.message(), Logger.Formatter.time(), keyword()) :: iodata()
  def format(level, message, {date, time}, metadata) do
    msg = IO.iodata_to_binary(message)

    base = %{
      "timestamp" => format_timestamp(date, time),
      "level" => to_string(level),
      "message" => msg
    }

    fields =
      metadata
      |> Keyword.take(metadata_keys())
      |> Enum.reduce(base, fn {k, v}, acc -> Map.put(acc, to_string(k), stringify(v)) end)

    case Jason.encode_to_iodata(fields) do
      {:ok, data} -> [data, ?\n]
      {:error, _} -> "#{inspect({date, time})} [#{level}] #{msg}\n"
    end
  end

  # A formatter that raises takes the logger handler down with it, so every
  # value has to survive. `to_string/1` does not: `:pid`, `:mfa`,
  # `:crash_reason` and `:file` are all standard Logger metadata and none of
  # them implement String.Chars — putting `:pid` in the roster would have
  # turned every log line into a formatter crash.
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v) when is_atom(v), do: to_string(v)
  defp stringify(v) when is_number(v), do: to_string(v)
  defp stringify(v), do: inspect(v)

  # The configured roster is the one source. A hardcoded copy here meant
  # adding a key required editing two files — and carried three keys the
  # config never requested, which therefore never arrived. The fallback is
  # what `Cyfr.LoggerContext` actually sets, so a missing config degrades to
  # the tenant fields rather than to nothing.
  defp metadata_keys do
    case :persistent_term.get(@roster_key, nil) do
      nil ->
        keys = resolve_metadata_keys()
        :persistent_term.put(@roster_key, keys)
        keys

      keys ->
        keys
    end
  end

  defp resolve_metadata_keys do
    case Application.get_env(:logger, :default_formatter, [])[:metadata] do
      keys when is_list(keys) -> keys
      _ -> Cyfr.LoggerContext.keys()
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
