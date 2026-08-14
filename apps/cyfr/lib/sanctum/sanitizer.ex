# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Sanitizer do
  @moduledoc """
  Sanitization utilities for sensitive data.

  Recursively traverses maps and lists, redacting any values whose
  keys match known sensitive patterns (passwords, tokens, API keys, etc.).

  Used by MCP request logging and any other context where user input
  may contain secrets that should not be persisted.
  """

  @sensitive_keys ~w(
    password secret token api_key apikey access_token refresh_token
    private_key secret_key auth bearer credential credentials
    passwd pwd api-key x-api-key authorization session_token
    session_id registry_token cosign_key signing_key jwt client_secret
    device_code stripe basic_auth
  )

  @doc """
  Sanitize data by redacting values under sensitive keys.

  Recursively traverses maps and lists. Keys matching known sensitive
  patterns are replaced with `"[REDACTED]"`.

  ## Examples

      iex> Sanctum.Sanitizer.sanitize(%{"password" => "s3cret", "name" => "test"})
      %{"password" => "[REDACTED]", "name" => "test"}

      iex> Sanctum.Sanitizer.sanitize(%{"nested" => %{"api_key" => "abc123"}})
      %{"nested" => %{"api_key" => "[REDACTED]"}}

  """
  @spec sanitize(term()) :: term()
  # Structs are traversed field-by-field and rebuilt, so one carrying a
  # sensitive field (a session token, a credential) is redacted like any other
  # map rather than passing through whole. Calendar and URI value structs
  # declare no sensitive field names, so they round-trip unchanged.
  def sanitize(%mod{} = data) do
    data
    |> Map.from_struct()
    |> sanitize()
    |> then(&struct(mod, &1))
  end

  def sanitize(data) when is_map(data) do
    data
    |> Enum.map(fn {key, value} ->
      if sensitive_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, sanitize(value)}
      end
    end)
    |> Map.new()
  end

  def sanitize(data) when is_list(data) do
    Enum.map(data, &sanitize/1)
  end

  # Tuples are traversed for the same reason maps and lists are: `{:error, %{...}}`
  # is the canonical Elixir error shape, so a credential that reaches a log
  # almost always arrives inside one. Without this clause the term fell through
  # to the catch-all untouched — which went unnoticed because the one struct that
  # carried a credential also derived `Inspect` redaction, so the *struct* hid
  # the value and the sanitizer never had to. That struct no longer holds a
  # credential, and the next one that does would not be protected.
  #
  # Structs match the clause above and never reach here.
  def sanitize(data) when is_tuple(data) do
    data
    |> Tuple.to_list()
    |> Enum.map(&sanitize/1)
    |> List.to_tuple()
  end

  def sanitize(data), do: data

  @doc """
  Check if a key matches a known sensitive pattern.

  Single-word patterns (`auth`, `token`, `secret`, …) must match a WHOLE token —
  so `auth` no longer redacts `authentication_method` / `device_auth_endpoint`.
  Multi-word patterns (`api_key`, `access_token`, …) keep substring matching on
  the separator-stripped key, so smushed variants (`apiKey`, `x-api-key`) stay
  covered. The net effect removes the common false positives without
  under-redacting real secret keys (which always carry a token boundary).
  """
  @spec sensitive_key?(term()) :: boolean()
  def sensitive_key?(key) when is_binary(key) do
    tokens = tokenize(key)
    normalized = String.downcase(key) |> String.replace(["-", "_"], "")

    Enum.any?(@sensitive_keys, fn pattern ->
      case tokenize(pattern) do
        [single] ->
          single in tokens

        _multi_word ->
          pattern_normalized = String.downcase(pattern) |> String.replace(["-", "_"], "")
          String.contains?(normalized, pattern_normalized)
      end
    end)
  end

  def sensitive_key?(key) when is_atom(key) do
    sensitive_key?(Atom.to_string(key))
  end

  def sensitive_key?(_), do: false

  # Split a key into lowercased alphanumeric tokens, breaking on separators
  # (`_`, `-`, `.`, space, …) AND camelCase boundaries so `apiKey` → ["api","key"].
  defp tokenize(string) do
    string
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1 \\2")
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
  end
end
