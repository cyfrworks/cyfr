# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.DisplayHelpers do
  @moduledoc """
  Shared display formatting helpers for Prism LiveViews.
  """

  @doc """
  Format an execution reference for display.

  Handles both legacy JSON-decoded map references and new canonical string references.
  """
  def format_ref(nil), do: "-"
  def format_ref(ref) when is_binary(ref), do: ref
  def format_ref(ref), do: inspect(ref)

  @doc """
  Format a byte count for display ("1.5 GB", "2.0 MB", "512 B").

  Non-integer values render as their string form; nil renders as "-".
  """
  def format_bytes(nil), do: "-"

  def format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  def format_bytes(val), do: to_string(val)

  @doc """
  Returns Tailwind class string for status badges.
  """
  def status_badge_class(status) do
    base = "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium"

    case to_string(status) do
      "success" -> "#{base} bg-green-900 text-green-300"
      "error" -> "#{base} bg-red-900 text-red-300"
      "pending" -> "#{base} bg-yellow-900 text-yellow-300"
      _ -> "#{base} bg-gray-800 text-gray-400"
    end
  end

  @doc """
  Formats integer ms to a display string like "123ms".
  """
  def format_duration("-"), do: "-"
  def format_duration(nil), do: "-"
  def format_duration(ms) when is_integer(ms), do: "#{ms}ms"
  def format_duration(ms), do: "#{ms}ms"

  @doc """
  Accesses a map field with atom key, falling back to string key.
  """
  def log_field(map, key), do: map[key] || map[to_string(key)] || "-"

  @doc """
  Checks if a field is present and non-empty in a map.
  """
  def has_field?(map, key) do
    val = map[key] || map[to_string(key)]
    val != nil && val != "" && val != "-"
  end

  @doc """
  Pretty-prints JSON strings or maps for display.
  """
  def format_json(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, decoded} ->
        case Jason.encode(decoded, pretty: true) do
          {:ok, json} -> json
          {:error, _} -> data
        end

      _ ->
        data
    end
  end

  def format_json(data) when is_map(data) or is_list(data) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(data, pretty: true)
    end
  end

  def format_json(data), do: inspect(data, pretty: true)

  @doc """
  Returns a human-readable relative time string from an ISO8601 timestamp.

  - < 60s: "just now"
  - < 60m: "2m ago"
  - < 24h: "1h ago"
  - < 7d: "3d ago"
  - >= 7d: the date string directly
  """
  def relative_time(nil), do: "-"
  def relative_time("-"), do: "-"

  def relative_time(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> relative_time_from_dt(dt)
      _ -> timestamp
    end
  end

  def relative_time(%DateTime{} = dt), do: relative_time_from_dt(dt)
  def relative_time(other), do: to_string(other)

  defp relative_time_from_dt(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
    end
  end
end
