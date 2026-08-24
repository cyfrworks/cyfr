# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Registry.Transport do
  @moduledoc """
  HTTP transport for the cyfr.run REST API (`/v1/*`).

  Sibling of `Compendium.OCI.Transport`, which does the same job for the OCI
  gateway, and shaped the same way on purpose: one entry point over
  `Cyfr.Network.pinned_request/5` (SSRF + DNS-rebinding protection), retry with
  exponential backoff, `Retry-After` honoured on 429, and a consistent
  `{:ok, status, headers, body} | {:error, Errors.t()}` return.

  ## What is retried, and what is not

  Retrying is only safe when the server cannot have acted on the request. That
  depends on both the method and how the attempt failed:

    * **429** — the server is explicitly saying it did not act. Retried for any
      method, after `Retry-After` when the response names one.
    * **A failure to reach the server at all** (connection refused, DNS,
      unreachable host) — nothing was sent. Retried for any method.
    * **5xx, or a timeout after the request was sent** — ambiguous: the server
      may have processed it and failed to answer. Retried only for idempotent
      methods. A `POST` that mints a push token, claims a namespace or files an
      appeal is not replayed, because a retry would mint a second token the
      caller never sees, or 409 a person against their own success.

  There is no `Idempotency-Key` on this API; until there is, not replaying is
  the only thing that keeps those endpoints honest.
  """

  require Logger

  alias Compendium.OCI.Errors

  @max_retries 3
  @base_delay_ms 500
  @receive_timeout 30_000

  # A retry of these cannot create a second effect, so an ambiguous failure is
  # safe to repeat. `:post` and `:patch` are deliberately absent.
  @idempotent_methods [:get, :head, :put, :delete, :options]

  # The request never left this host, so nothing can have acted on it.
  @unreached_reasons [:econnrefused, :nxdomain, :ehostunreach, :enetunreach, :ehostdown]

  @type response ::
          {:ok, non_neg_integer(), [{String.t(), String.t()}], binary()} | {:error, Errors.t()}

  @doc """
  One path segment of a registry URL, escaped.

  `URI.encode/1`'s default predicate leaves the reserved characters alone —
  `URI.encode("a/b") == "a/b"` — so a slug or component name interpolated into
  a path could otherwise rewrite the path it was placed in. Every unreserved
  character a real slug, namespace or version uses survives untouched.
  """
  @spec path_segment(String.t()) :: String.t()
  def path_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  @doc """
  Issue a request to the registry REST API.

  `url` is absolute; headers and body are passed through untouched.

  ## Options

    * `:receive_timeout` — ms to wait for a response (default #{@receive_timeout}).
    * `:retry` — set `false` for a best-effort call whose caller has its own
      deadline; a single attempt is made and any failure is returned as-is.
  """
  @spec request(atom(), String.t(), [{String.t(), String.t()}], binary() | nil, keyword()) ::
          response()
  def request(method, url, headers, body, opts \\ []) do
    limits = %{
      receive_timeout: Keyword.get(opts, :receive_timeout, @receive_timeout),
      max_attempts: if(Keyword.get(opts, :retry, true), do: @max_retries, else: 1)
    }

    do_request(method, url, headers, body, 0, limits)
  end

  # A backstop on the only recursion in this module: `retry_or_give_up/10`
  # already refuses to recurse past the budget.
  defp do_request(_method, _url, _headers, _body, attempt, %{max_attempts: max})
       when attempt >= max do
    Logger.error("[Compendium.Registry.Transport] All #{max} attempts exhausted")
    {:error, Errors.api_connection_error(:max_retries_exceeded)}
  end

  defp do_request(method, url, headers, body, attempt, limits) do
    # The registry host is operator config and may be a self-hosted cyfr.run on
    # a private network, so private targets are allowed exactly as far as the
    # operator's egress policy allows — the same posture the OCI transport takes.
    result =
      Cyfr.Network.pinned_request(method, url, headers, body,
        receive_timeout: limits.receive_timeout,
        allow_private: :policy
      )

    case result do
      {:ok, 429, resp_headers, resp_body} ->
        retry_or_give_up(
          method,
          url,
          headers,
          body,
          attempt,
          limits,
          # A 429 says the request was refused, not performed.
          :always,
          "429",
          max(retry_after_ms(resp_headers), backoff(attempt)),
          fn -> {:error, Errors.from_api_response(429, resp_body, "request")} end
        )

      {:ok, status, _resp_headers, resp_body} when status >= 500 ->
        retry_or_give_up(
          method,
          url,
          headers,
          body,
          attempt,
          limits,
          :if_idempotent,
          "#{status}",
          backoff(attempt),
          fn -> {:error, Errors.from_api_response(status, resp_body, "request")} end
        )

      {:ok, status, resp_headers, resp_body} ->
        {:ok, status, resp_headers, resp_body}

      # An SSRF/DNS validation refusal is a decision, not a fault: never retry.
      {:error, reason} when is_binary(reason) ->
        Logger.error("[Compendium.Registry.Transport] Blocked request: #{reason}")
        {:error, Errors.api_connection_error(reason)}

      {:error, reason} ->
        retry_or_give_up(
          method,
          url,
          headers,
          body,
          attempt,
          limits,
          if(unreached?(reason), do: :always, else: :if_idempotent),
          inspect(reason),
          backoff(attempt),
          fn -> {:error, Errors.api_connection_error(reason)} end
        )
    end
  end

  defp retry_or_give_up(method, url, headers, body, attempt, limits, when_to, why, delay, give_up) do
    cond do
      attempt + 1 >= limits.max_attempts ->
        Logger.error("[Compendium.Registry.Transport] #{why} on final attempt — giving up")
        give_up.()

      when_to == :if_idempotent and method not in @idempotent_methods ->
        Logger.error(
          "[Compendium.Registry.Transport] #{why} for #{method_string(method)} — not retrying: " <>
            "the server may have acted on it and this API has no idempotency key"
        )

        give_up.()

      true ->
        Logger.warning(
          "[Compendium.Registry.Transport] #{why}, retrying in #{delay}ms " <>
            "(attempt #{attempt + 1}/#{limits.max_attempts})"
        )

        Process.sleep(delay)
        do_request(method, url, headers, body, attempt + 1, limits)
    end
  end

  defp backoff(attempt), do: @base_delay_ms * Integer.pow(2, attempt)

  defp unreached?(%{reason: reason}), do: unreached?(reason)
  defp unreached?(reason) when reason in @unreached_reasons, do: true
  defp unreached?(_), do: false

  defp retry_after_ms(headers) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, value} ->
        case Integer.parse(value) do
          {seconds, _} -> seconds * 1000
          :error -> 0
        end

      _ ->
        0
    end
  end

  defp method_string(method), do: method |> Atom.to_string() |> String.upcase()
end
