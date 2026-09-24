# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.EnvValue do
  @moduledoc """
  Strict readers of single environment variables, for the runtime
  configuration of every release.

  An unset or blank variable answers its default (`switch/3`) or `nil`
  (every other reader), so the caller keeps the setting's default; a set
  variable that does not parse answers `{:error, message}` naming the
  variable and the accepted form, so the caller refuses the boot instead
  of running with a value the operator did not choose. No message echoes
  a secret: `hex_key/2` names the variable and the form only.

  Every reader takes a `getenv` — `(String.t() -> String.t() | nil)` — so
  it is exercised in tests without touching the real environment.
  """

  @type getenv :: (String.t() -> String.t() | nil)

  @doc """
  An on/off switch: `on`/`off`, `true`/`false`, `yes`/`no` or `1`/`0`,
  ignoring case. Unset or blank is `default`.
  """
  @spec switch(getenv(), String.t(), boolean()) :: {:ok, boolean()} | {:error, String.t()}
  def switch(getenv, key, default) when is_function(getenv, 1) and is_boolean(default) do
    case trimmed(getenv, key) do
      nil ->
        {:ok, default}

      raw ->
        case String.downcase(raw) do
          on when on in ["on", "true", "yes", "1"] -> {:ok, true}
          off when off in ["off", "false", "no", "0"] -> {:ok, false}
          _ -> {:error, "#{key}=#{inspect(raw)} is not a switch; use on or off."}
        end
    end
  end

  @doc "A duration in whole milliseconds within `range`; see `whole_number/4`."
  @spec milliseconds(getenv(), String.t(), Range.t()) ::
          {:ok, non_neg_integer() | nil} | {:error, String.t()}
  def milliseconds(getenv, key, range), do: whole_number(getenv, key, range, "milliseconds")

  @doc """
  A whole number of `unit` within `range`. Anything but a decimal integer
  inside `range` — a unit suffix, a fraction, a sign — is an error naming
  the unit and the range.
  """
  @spec whole_number(getenv(), String.t(), Range.t(), String.t()) ::
          {:ok, non_neg_integer() | nil} | {:error, String.t()}
  def whole_number(getenv, key, _first.._last//1 = range, unit)
      when is_function(getenv, 1) and is_binary(unit),
      do: bounded(getenv, key, range, unit, 12)

  @doc """
  A count of bytes within `range`, spelled as a whole number of bytes: a
  memory bound, whose range reaches past what `whole_number/4` reads (1 TiB
  is thirteen digits). It reads as many digits as the range's upper end
  has, and refuses a unit suffix, a fraction, a sign or a value outside
  `range` as `whole_number/4` does.
  """
  @spec bytes(getenv(), String.t(), Range.t()) ::
          {:ok, non_neg_integer() | nil} | {:error, String.t()}
  def bytes(getenv, key, _first..last//1 = range)
      when is_function(getenv, 1) and is_integer(last) and last >= 0,
      do: bounded(getenv, key, range, "bytes", length(Integer.digits(last)))

  # A decimal integer of at most `digits` digits inside `range`, so no
  # spelling makes the reader convert more text than the range can hold.
  defp bounded(getenv, key, first..last//1 = range, unit, digits) do
    case trimmed(getenv, key) do
      nil ->
        {:ok, nil}

      text ->
        if byte_size(text) <= digits and Regex.match?(~r/\A[0-9]+\z/, text) and
             String.to_integer(text) in range do
          {:ok, String.to_integer(text)}
        else
          {:error,
           "#{key}=#{inspect(text)} must be a whole number of #{unit} from #{first} to #{last}."}
        end
    end
  end

  @doc "The variable's text, trimmed; unset or blank is `nil`."
  @spec text(getenv(), String.t()) :: {:ok, String.t() | nil}
  def text(getenv, key) when is_function(getenv, 1), do: {:ok, trimmed(getenv, key)}

  @doc """
  A 32-byte key spelled as exactly 64 hexadecimal digits, in either case
  (`Prima.MacEnvelope.decode_root/1`), decoded. The error names the form,
  never the value.
  """
  @spec hex_key(getenv(), String.t()) :: {:ok, binary() | nil} | {:error, String.t()}
  def hex_key(getenv, key) when is_function(getenv, 1) do
    case trimmed(getenv, key) do
      nil ->
        {:ok, nil}

      text ->
        case Prima.MacEnvelope.decode_root(text) do
          {:ok, bytes} -> {:ok, bytes}
          :error -> {:error, "#{key} must be 64 hexadecimal digits (a 32-byte key)."}
        end
    end
  end

  @doc "A TCP port from 1 to 65535."
  @spec port(getenv(), String.t()) :: {:ok, :inet.port_number() | nil} | {:error, String.t()}
  def port(getenv, key) when is_function(getenv, 1) do
    case trimmed(getenv, key) do
      nil ->
        {:ok, nil}

      text ->
        case Integer.parse(text) do
          {port, ""} when port in 1..65_535 -> {:ok, port}
          _ -> {:error, "#{key}=#{inspect(text)} is not a port from 1 to 65535."}
        end
    end
  end

  @doc "An IPv4 or IPv6 address to bind, as `:inet` reads it."
  @spec bind(getenv(), String.t()) :: {:ok, :inet.ip_address() | nil} | {:error, String.t()}
  def bind(getenv, key) when is_function(getenv, 1) do
    case trimmed(getenv, key) do
      nil ->
        {:ok, nil}

      text ->
        case :inet.parse_address(String.to_charlist(text)) do
          {:ok, address} -> {:ok, address}
          {:error, _} -> {:error, "#{key}=#{inspect(text)} is not an IPv4 or IPv6 address."}
        end
    end
  end

  @doc """
  A base URL a route is appended to: `http` or `https` with a host and no
  path, query, fragment or credentials (`Prima.WorkerWire.base_url/1`),
  without its trailing slash.
  """
  @spec url(getenv(), String.t()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def url(getenv, key) when is_function(getenv, 1) do
    case trimmed(getenv, key) do
      nil ->
        {:ok, nil}

      text ->
        case Prima.WorkerWire.base_url(text) do
          {:ok, base} ->
            {:ok, base}

          :error ->
            {:error,
             "#{key}=#{inspect(text)} must be an http or https URL with a host and no path."}
        end
    end
  end

  defp trimmed(getenv, key) do
    case getenv.(key) do
      nil ->
        nil

      raw when is_binary(raw) ->
        case String.trim(raw) do
          "" -> nil
          text -> text
        end
    end
  end
end
