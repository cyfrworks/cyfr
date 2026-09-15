# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.StatusRedaction do
  @moduledoc """
  What the MCP bridge controller (`Emissary.MCP.Bridge`) and a server
  process (`Emissary.MCP.ExternalServer`) show of themselves in
  `:sys.get_status/1` and in crash reports.

  `format_status/1` redacts a `format_status/1` callback's state, last
  message, exit reason and debug log however deeply a secret is held in
  them — an in-flight message's spec, a grant in a mailbox message, a state
  passed as an argument in a crash's stacktrace. Every value under a map or
  keyword key named `root`, `control_key`, `seal_key`, `owner_key`,
  `sealed` or `env` becomes `"[REDACTED]"`, and every value of a `headers`
  or `raw_headers` map does, its header names kept.
  """

  @redacted "[REDACTED]"
  @secret_keys [:root, :control_key, :seal_key, :owner_key, :sealed, :env]
  @header_maps [:headers, :raw_headers]
  @status_terms [:state, :message, :reason, :log]

  @doc "A `format_status/1` callback's status map with its state, message, reason and log redacted."
  @spec format_status(map()) :: map()
  def format_status(status) when is_map(status) do
    Map.new(status, fn
      {key, value} when key in @status_terms -> {key, redact(value)}
      other -> other
    end)
  end

  @doc "`term` with every secret it holds, at any depth, redacted."
  @spec redact(term()) :: term()
  def redact(%module{} = struct) do
    struct |> Map.from_struct() |> redact_map() |> then(&struct(module, &1))
  end

  def redact(map) when is_map(map), do: Map.new(map, &redact_pair/1)
  def redact(list) when is_list(list), do: redact_list(list)

  # A keyword entry is redacted as a map entry is.
  def redact({key, _value} = pair) when is_atom(key), do: redact_pair(pair)

  def redact(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> redact_list() |> List.to_tuple()

  def redact(other), do: other

  defp redact_map(map), do: Map.new(map, &redact_pair/1)

  defp redact_pair({key, _value}) when key in @secret_keys, do: {key, @redacted}

  defp redact_pair({key, headers}) when key in @header_maps and is_map(headers),
    do: {key, Map.new(headers, fn {name, _value} -> {name, @redacted} end)}

  defp redact_pair({key, value}), do: {redact(key), redact(value)}

  # Improper lists (iodata in a log entry) keep their shape.
  defp redact_list([head | tail]), do: [redact(head) | redact_list(tail)]
  defp redact_list([]), do: []
  defp redact_list(tail), do: redact(tail)
end
