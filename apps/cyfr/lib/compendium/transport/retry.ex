# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Transport.Retry do
  @moduledoc """
  The retry decision the two Compendium transports share.

  `Compendium.Registry.Transport` (cyfr.run REST) and
  `Compendium.OCI.Transport` (the OCI gateway) keep their own loops, auth
  injection and error types — what they must not keep separately is the
  policy: which outcomes may be retried at all, which only for idempotent
  methods, and how long to wait. That decision is pure and lives here, so
  a fix lands in both transports at once.

  Retrying is only safe when the server cannot have acted on the request:

    * **429** — the server says it did not act. Retry for any method,
      honouring `Retry-After`.
    * **A failure to reach the server at all** — nothing was sent. Retry
      for any method.
    * **5xx, or a timeout after the request was sent** — ambiguous: the
      server may have processed it and failed to answer. Retry only
      idempotent methods; a POST that may have minted is never replayed.
    * **An SSRF/DNS refusal** (a binary reason from `Cyfr.Network`) — a
      decision, not a fault. Never retried.
  """

  @base_delay_ms 500
  @max_retry_after_ms 30_000

  # A retry of these cannot create a second effect, so an ambiguous
  # failure is safe to repeat. `:post` and `:patch` are deliberately absent.
  @idempotent_methods [:get, :head, :put, :delete, :options]

  # The request never left this host, so nothing can have acted on it.
  @unreached_reasons [:econnrefused, :nxdomain, :ehostunreach, :enetunreach, :ehostdown]

  @type disposition :: :retry_always | :retry_if_idempotent | :never

  @doc "How an outcome may be retried, before the method is considered."
  @spec classify({:status, non_neg_integer()} | {:error, term()}) :: disposition()
  def classify({:status, 429}), do: :retry_always
  def classify({:status, status}) when status >= 500, do: :retry_if_idempotent
  def classify({:status, _status}), do: :never
  def classify({:error, reason}) when is_binary(reason), do: :never

  def classify({:error, reason}),
    do: if(unreached?(reason), do: :retry_always, else: :retry_if_idempotent)

  @doc "Whether a retry of `method` can create a second effect."
  @spec idempotent?(atom()) :: boolean()
  def idempotent?(method), do: method in @idempotent_methods

  @doc """
  Milliseconds a `Retry-After` header asks for — delta-seconds or an
  HTTP-date — clamped to #{@max_retry_after_ms}ms so a hostile or
  confused server cannot park a request process for minutes. 0 when the
  header is absent or unreadable.
  """
  @spec retry_after_ms([{String.t(), String.t()}]) :: non_neg_integer()
  def retry_after_ms(headers) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, value} -> value |> parse_retry_after() |> min(@max_retry_after_ms) |> max(0)
      nil -> 0
    end
  end

  @doc "Exponential backoff for a 0-based `attempt`: #{@base_delay_ms}ms doubling."
  @spec backoff(non_neg_integer()) :: pos_integer()
  def backoff(attempt), do: @base_delay_ms * Integer.pow(2, attempt)

  defp parse_retry_after(value) do
    case Integer.parse(value) do
      {seconds, _rest} ->
        seconds * 1000

      :error ->
        case :httpd_util.convert_request_date(String.to_charlist(value)) do
          {{_, _, _}, {_, _, _}} = erl_datetime ->
            date_s = :calendar.datetime_to_gregorian_seconds(erl_datetime)
            now_s = :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())
            (date_s - now_s) * 1000

          _bad_date ->
            0
        end
    end
  end

  defp unreached?(%{reason: reason}), do: unreached?(reason)
  defp unreached?(reason) when reason in @unreached_reasons, do: true
  defp unreached?(_reason), do: false
end
