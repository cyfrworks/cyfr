# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Sanitizer do
  @moduledoc """
  Sanitization utilities for sensitive data.

  Recursively traverses maps and lists, redacting any values whose
  keys match known sensitive patterns (passwords, tokens, API keys, etc.).

  Used by MCP request logging and any other context where user input
  may contain secrets that should not be persisted.
  """

  # The `*_key` family is enumerated rather than matched by suffix, for the
  # same reason `code` is exact-matched below: a `_key` rule would redact
  # `sort_key`, `cache_key`, `partition_key` and `idempotency_key`, which are
  # the values you most want to read when one of those goes wrong. What was
  # missing is the crypto half — `keyring` names the boot config the entire
  # at-rest scheme hangs on, and `master_key` / `encryption_key` / `hmac_key`
  # are the material itself.
  @sensitive_keys ~w(
    password secret token api_key apikey access_token refresh_token
    private_key secret_key auth bearer credential credentials
    passwd pwd api-key x-api-key authorization session_token
    session_id registry_token cosign_key signing_key jwt client_secret
    device_code stripe basic_auth cookie signature code_verifier
    proof ticket
    keyring crypto_keyring master_key encryption_key hmac_key
    derived_key key_material keystore passphrase
  )

  # Match code, state, key and fields only as whole keys after stripping
  # separators. These can carry credentials — `fields` is a vault entry's
  # material, name → value, whatever the names are; longer names such as
  # error_code, keyboard, connection_state and field_names must remain
  # readable.
  @exact_sensitive_keys ~w(code state key fields)

  # Compared against the key as written, separators and all. `_t` and
  # `_session` are the tincture credential query params
  # (`Sanctum.TinctureAuth.sensitive_query_keys/0`, pinned to this roster by
  # test): the plug scrubs them from `conn.query_string`, but the same names
  # arrive again as decoded params, where it cannot reach them. They stay
  # here rather than in the list above because their bare spellings are not
  # credentials — `session` is usually a session object worth reading in an
  # error, and `t` is a short name for anything.
  @exact_raw_sensitive_keys ~w(_t _session)

  @doc """
  The redaction vocabulary as Phoenix's `:filter_parameters` consumes it.

  Set into `config :phoenix, :filter_parameters` at boot by
  `Cyfr.Application`, so inbound request-param logging redacts by the same
  roster as everything else. Phoenix matches by substring, which
  over-covers relative to `sensitive_key?/1`'s token matching — the safe
  direction for a log.
  """
  @spec filter_parameters() :: [String.t()]
  def filter_parameters,
    do: @sensitive_keys ++ @exact_sensitive_keys ++ @exact_raw_sensitive_keys

  @doc """
  Sanitize data by redacting values under sensitive keys.

  Recursively traverses maps and lists. Keys matching known sensitive
  patterns are replaced with `"[REDACTED]"`.

  ## Examples

      iex> Prima.Sanitizer.sanitize(%{"password" => "s3cret", "name" => "test"})
      %{"password" => "[REDACTED]", "name" => "test"}

      iex> Prima.Sanitizer.sanitize(%{"nested" => %{"api_key" => "abc123"}})
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

  # Check two-tuples as key/value pairs before traversing general tuples.
  # This redacts credential headers such as {"authorization", "Bearer ..."}.
  # Structs are handled by the preceding clause.
  def sanitize({key, value}) when is_binary(key) or is_atom(key) do
    if sensitive_key?(key), do: {key, "[REDACTED]"}, else: {key, sanitize(value)}
  end

  def sanitize(data) when is_tuple(data) do
    data
    |> Tuple.to_list()
    |> Enum.map(&sanitize/1)
    |> List.to_tuple()
  end

  def sanitize(data), do: data

  @doc """
  Check if a key matches a known sensitive pattern.

  Single-word patterns (`auth`, `token`, `secret`) match whole tokens.
  Multi-word patterns (`api_key`, `access_token`) match substrings after
  separator removal, including `apiKey` and `x-api-key`.

  A third rule covers keys sensitive only in full: `code` is an OAuth
  authorization code, but `error_code` and `code_challenge` are not secrets.
  """
  @spec sensitive_key?(term()) :: boolean()
  def sensitive_key?(key) when is_binary(key) do
    tokens = tokenize(key)
    normalized = String.downcase(key) |> String.replace(["-", "_"], "")

    String.downcase(key) in @exact_raw_sensitive_keys or
      normalized in @exact_sensitive_keys or
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
