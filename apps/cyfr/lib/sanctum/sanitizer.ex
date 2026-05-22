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
    registry_token cosign_key signing_key jwt client_secret
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
  def sanitize(%{__struct__: _} = data), do: data

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

  def sanitize(data), do: data

  @doc """
  Check if a key matches a known sensitive pattern.
  """
  @spec sensitive_key?(term()) :: boolean()
  def sensitive_key?(key) when is_binary(key) do
    normalized = String.downcase(key) |> String.replace(["-", "_"], "")

    Enum.any?(@sensitive_keys, fn sensitive ->
      normalized_sensitive = String.downcase(sensitive) |> String.replace(["-", "_"], "")
      String.contains?(normalized, normalized_sensitive)
    end)
  end

  def sensitive_key?(key) when is_atom(key) do
    sensitive_key?(Atom.to_string(key))
  end

  def sensitive_key?(_), do: false
end
