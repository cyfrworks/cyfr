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

  # Keys sensitive only when they are the WHOLE key. `code` is the OAuth
  # authorization code — a single-use credential — but it is also the tail of
  # `error_code`, `status_code` and `code_challenge`, none of which are
  # secret and all of which are worth reading in a log. Whole-token matching
  # is not enough to tell those apart; exact matching is. `state` is the
  # vault-OAuth CSRF binding — but "state" as a token inside a longer key
  # (an execution's state, a connection state) is ordinary data.
  #
  # `key` is a credential wherever it stands alone: it is the `key` argument
  # of `key.validate` (an API key value, which reached `mcp_logs` in the
  # clear) and the `_key` tincture query param — separators are stripped
  # before this comparison, so both spellings land here. `keyboard` and
  # `monkey` are words and keep reading.
  @exact_sensitive_keys ~w(code state key)

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
  #
  # A 2-tuple is checked as a key/value pair first. `Plug.Conn`'s
  # `req_headers` is a list of `{name, value}` — the single most likely shape
  # for a credential to arrive in — and the general tuple clause below
  # sanitizes each element independently, so the name was never consulted as
  # a key and `{"authorization", "Bearer …"}` went to the log intact.
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

  Single-word patterns (`auth`, `token`, `secret`, …) must match a WHOLE token —
  so `auth` no longer redacts `authentication_method` / `device_auth_endpoint`.
  Multi-word patterns (`api_key`, `access_token`, …) keep substring matching on
  the separator-stripped key, so smushed variants (`apiKey`, `x-api-key`) stay
  covered. The net effect removes the common false positives without
  under-redacting real secret keys (which always carry a token boundary).

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
