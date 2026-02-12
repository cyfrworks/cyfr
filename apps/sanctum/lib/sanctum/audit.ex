defmodule Sanctum.Audit do
  require Logger
  @moduledoc """
  Audit logging for CYFR.

  Provides append-only audit logging with filtering and export capabilities.
  Events are stored as JSON lines organized by date for efficient querying.

  Routes all persistent storage through `Arca.MCP.handle("audit_log", ...)`
  which owns path construction, file writes, and SQLite indexing.
  Keeps export/CSV formatting locally.

  ## Usage

      ctx = Sanctum.Context.local()

      # Log an event
      :ok = Sanctum.Audit.log(ctx, "execution", %{component: "stripe-catalyst", duration_ms: 150})

      # List recent events
      {:ok, events} = Sanctum.Audit.list(ctx, %{limit: 100})

      # Export events
      {:ok, csv_data} = Sanctum.Audit.export(ctx, %{format: "csv"})
  """

  alias Sanctum.Context

  @default_limit 100

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Log an audit event.

  ## Event Types

  - `"execution"` - Component execution events
  - `"auth"` - Authentication events (login, logout)
  - `"policy"` - Policy evaluation events
  - `"secret_access"` - Secret read/write events
  """
  def log(%Context{} = ctx, event_type, data) when is_binary(event_type) and is_map(data) do
    case Arca.MCP.handle("audit_log", ctx, %{
      "action" => "log",
      "event_type" => event_type,
      "data" => data
    }) do
      {:ok, %{logged: true}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  List audit events with optional filters.

  ## Filters

  - `:event_type` - Filter by event type
  - `:start_date` - Filter events after this date (ISO 8601 date, e.g. "2025-01-01")
  - `:end_date` - Filter events before this date (ISO 8601 date)
  - `:limit` - Maximum number of events to return (default: 100)
  - `:offset` - Number of events to skip
  """
  def list(%Context{} = ctx, filters \\ %{}) do
    opts = normalize_filters(filters)

    args = %{"action" => "list"}
    args = if opts[:limit], do: Map.put(args, "limit", opts[:limit]), else: args
    args = if opts[:event_type], do: Map.put(args, "event_type", opts[:event_type]), else: args

    case Arca.MCP.handle("audit_log", ctx, args) do
      {:ok, %{events: events}} ->
        # Convert atom-keyed maps to string-keyed maps for consistent API
        events = Enum.map(events, &atom_map_to_string_map/1)

        # Apply additional filtering that the MCP handler doesn't handle
        start_date = parse_filter_date(filters[:start_date] || filters["start_date"])
        end_date = parse_filter_date(filters[:end_date] || filters["end_date"])

        events =
          events
          |> filter_by_date_range(start_date, end_date)
          |> apply_pagination(filters)

        {:ok, events}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Export audit events in the specified format.

  ## Options

  - `:format` - Export format: "json" (default) or "csv"
  - All filters from `list/2` are also supported
  """
  def export(%Context{} = ctx, opts \\ %{}) do
    format = Map.get(opts, :format, "json")
    filters = Map.drop(opts, [:format])

    with {:ok, events} <- list(ctx, Map.put(filters, :limit, :infinity)) do
      case format do
        "csv" -> {:ok, to_csv(events)}
        "json" -> {:ok, Jason.encode!(events, pretty: true)}
        _ -> {:error, "Unknown format: #{format}"}
      end
    end
  end

  # ============================================================================
  # Internal - Filtering
  # ============================================================================

  defp normalize_filters(filters) when is_map(filters) do
    limit = filters[:limit] || filters["limit"] || @default_limit
    event_type = filters[:event_type] || filters["event_type"]
    start_date = filters[:start_date] || filters["start_date"]
    end_date = filters[:end_date] || filters["end_date"]

    opts = [limit: limit]
    opts = if event_type, do: Keyword.put(opts, :event_type, event_type), else: opts
    opts = if start_date, do: Keyword.put(opts, :start_date, start_date), else: opts
    opts = if end_date, do: Keyword.put(opts, :end_date, end_date), else: opts
    opts
  end

  defp normalize_filters(filters) when is_list(filters), do: filters

  defp filter_by_date_range(events, nil, nil), do: events

  defp filter_by_date_range(events, start_date, end_date) do
    start_iso = if start_date, do: Date.to_iso8601(start_date), else: nil
    end_iso = if end_date, do: Date.to_iso8601(end_date) <> "T23:59:59Z", else: nil

    Enum.filter(events, fn e ->
      ts = e["timestamp"]
      (start_iso == nil or ts >= start_iso) and (end_iso == nil or ts <= end_iso)
    end)
  end

  defp apply_pagination(events, filters) do
    limit = filters[:limit] || filters["limit"] || @default_limit
    offset = filters[:offset] || filters["offset"] || 0

    events
    |> Enum.drop(offset)
    |> then(fn evts ->
      if limit == :infinity, do: evts, else: Enum.take(evts, limit)
    end)
  end

  defp parse_filter_date(nil), do: nil
  defp parse_filter_date(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, d} -> d
      {:error, _} -> nil
    end
  end
  defp parse_filter_date(%Date{} = date), do: date

  # ============================================================================
  # Internal - Format Conversion
  # ============================================================================

  defp atom_map_to_string_map(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  # ============================================================================
  # Internal - Export
  # ============================================================================

  defp to_csv(events) do
    headers = ["timestamp", "event_type", "user_id", "org_id", "request_id", "session_id", "data"]
    header_line = Enum.join(headers, ",")

    lines =
      Enum.map(events, fn event ->
        [
          escape_csv(event["timestamp"]),
          escape_csv(event["event_type"]),
          escape_csv(event["user_id"]),
          escape_csv(event["org_id"]),
          escape_csv(event["request_id"]),
          escape_csv(event["session_id"]),
          escape_csv(Jason.encode!(event["data"]))
        ]
        |> Enum.join(",")
      end)

    Enum.join([header_line | lines], "\n")
  end

  defp escape_csv(nil), do: ""

  defp escape_csv(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  defp escape_csv(value), do: escape_csv(to_string(value))
end
