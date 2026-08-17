# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.DisplayHelpers do
  @moduledoc """
  Shared display formatting helpers for Prism LiveViews.
  """

  @doc """
  A short human label for a principal id as it appears on executions, logs
  and messages: a person (their display name, else email, else a shortened
  id) or one of the server's synthetic principals — `system`, `_seed`,
  `_health_probe`, `_system_scan`, `webhook:<slug>`, `_tincture` — which
  are never people and read as what they are.
  """
  @spec principal_label(String.t() | nil) :: String.t()
  def principal_label(nil), do: "-"
  def principal_label("system"), do: "System"
  def principal_label("_seed"), do: "System (seed)"
  def principal_label("_health_probe"), do: "System (health probe)"
  def principal_label("_system_scan"), do: "System (scan)"
  def principal_label("_tincture"), do: "Public tincture"
  def principal_label("webhook:" <> slug), do: "Webhook " <> slug
  def principal_label("aqua"), do: "AQUA"

  def principal_label(user_id) when is_binary(user_id) do
    case Sanctum.Tenancy.Users.get(user_id) do
      {:ok, %{display_name: name}} when is_binary(name) and name != "" -> name
      {:ok, %{email: email}} when is_binary(email) and email != "" -> email
      _ -> short_id(user_id)
    end
  end

  def principal_label(other), do: inspect(other)

  defp short_id(id) when byte_size(id) > 24, do: String.slice(id, 0, 24) <> "…"
  defp short_id(id), do: id

  @doc """
  Format an execution reference for display. Non-binary values render via
  `inspect/1` as a defensive fallback.
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
  Formats integer ms to a display string like "123ms".
  """
  def format_duration("-"), do: "-"
  def format_duration(nil), do: "-"
  def format_duration(ms) when is_integer(ms), do: "#{ms}ms"
  def format_duration(ms), do: "#{ms}ms"

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
