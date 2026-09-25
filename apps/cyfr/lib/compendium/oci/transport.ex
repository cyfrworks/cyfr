# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.OCI.Transport do
  @moduledoc """
  HTTP transport layer for OCI Distribution API calls.

  Issues requests via `Sanctum.Egress.pinned_request/5` (SSRF + DNS-rebinding
  protection) and adds:
  - Automatic auth header injection via `OCI.Auth`, recomputed per attempt
    so a retry picks up a rotated token; a stored token that cannot be read
    refuses the request (`:registry_unavailable`) before anything is sent
  - Retry with backoff, idempotency-gated for ambiguous failures — the
    policy is `Compendium.Transport.Retry`, shared with the REST transport
  - Consistent return format: `{:ok, status, headers, body}` or `{:error, reason}`

  A 401 is surfaced, never negotiated: push tokens do no realm exchange,
  so the caller prompts re-login (`OCI.Auth` says why at length).
  """

  require Logger

  alias Compendium.OCI.{Auth, Errors, Reference}
  alias Compendium.Transport.Retry

  @max_retries 3
  @receive_timeout 120_000

  # Ceiling for API-shaped responses (manifests, tag lists, catalog pages,
  # upload-session acks) when the caller names no bound of its own. Blob
  # downloads pass their content-shaped ceiling via `:max_response_bytes`.
  @default_max_response_bytes 10 * 1024 * 1024

  @type response :: {:ok, integer(), [{String.t(), String.t()}], binary()}
  # A damaged stored push token answers as itself, before any request.
  @type error :: {:error, Errors.t() | String.t() | {:corrupt, :registry_credential}}

  @doc """
  Perform an HTTP request to an OCI registry endpoint.

  Automatically injects auth headers and handles 401 challenges.
  Retries on 5xx errors with exponential backoff.

  `ctx` is required (caller-first, matching the codebase convention) so the
  per-namespace push token is attached on writes. Pass `nil` only for the
  genuinely-public catalog reads (`discover`, `pull_bytes`).

  ## Options

    * `:max_response_bytes` — response-size ceiling, enforced while the
      body streams in (default #{@default_max_response_bytes}). Blob
      downloads pass the ceiling their content shape allows.
  """
  @spec request(
          Sanctum.Context.t() | nil,
          atom(),
          String.t(),
          Reference.t(),
          [{String.t(), String.t()}],
          binary() | nil,
          keyword()
        ) ::
          response() | error()
  def request(ctx, method, path, %Reference{} = ref, extra_headers \\ [], body \\ nil, opts \\ []) do
    base_url = Reference.api_base(ref)
    url = base_url <> path

    do_request_with_retry(
      method,
      url,
      ref.registry,
      ref.repository,
      extra_headers,
      body,
      ctx,
      opts,
      0
    )
  end

  @doc """
  Perform an HTTP request to an arbitrary URL (used for blob uploads where
  the registry may return a different location URL).

  `ctx` is required (caller-first) for the same reason as `request/7`,
  and `opts` carries the same `:max_response_bytes`.
  """
  @spec request_url(
          Sanctum.Context.t() | nil,
          atom(),
          String.t(),
          String.t(),
          String.t(),
          [{String.t(), String.t()}],
          binary() | nil,
          keyword()
        ) ::
          response() | error()
  def request_url(
        ctx,
        method,
        url,
        registry,
        repository,
        extra_headers \\ [],
        body \\ nil,
        opts \\ []
      ) do
    do_request_with_retry(method, url, registry, repository, extra_headers, body, ctx, opts, 0)
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp do_request_with_retry(
         _method,
         _url,
         registry,
         _repository,
         _headers,
         _body,
         _ctx,
         _opts,
         attempt
       )
       when attempt >= @max_retries do
    Logger.error(
      "[Compendium.OCI.Transport] All #{@max_retries} retries exhausted for #{registry}"
    )

    {:error, Errors.connection_error(registry, :max_retries_exceeded)}
  end

  defp do_request_with_retry(
         method,
         url,
         registry,
         repository,
         extra_headers,
         body,
         ctx,
         opts,
         attempt
       ) do
    namespace_slug = namespace_from_repository(repository)
    # A push token that cannot be read is the credential store's answer, not
    # the registry's: it comes back at once, with no request sent and no
    # retry, and is never replaced by an anonymous request.
    with {:ok, auth_headers} <- Auth.auth_headers(registry, repository, namespace_slug, ctx) do
      headers = auth_headers ++ extra_headers

      # pinned_request validates the resolved IP and connects to it directly (no
      # second DNS resolution → no rebinding), preserving SNI/Host. A private
      # registry is reachable only when the operator named it in the
      # private-egress allowlist. The size ceiling is enforced while the body
      # streams in — a hostile registry cannot flood the host's heap.
      case Sanctum.Egress.pinned_request(method, url, headers, body,
             receive_timeout: @receive_timeout,
             private_policy: :operator,
             max_response_bytes:
               Keyword.get(opts, :max_response_bytes, @default_max_response_bytes)
           ) do
        {:ok, 401, resp_headers, resp_body} ->
          # Push tokens don't do realm exchange. 401 means the token is missing
          # or revoked — surface it to the caller so they can prompt re-login.
          # The WWW-Authenticate: Basic realm=... header is still emitted by
          # the server for Docker/OCI compatibility, but we don't act on it.
          _ = resp_headers

          Logger.info(
            "[Compendium.OCI.Transport] 401 from #{registry}/#{repository} (namespace=#{namespace_slug}) — " <>
              "push token missing or revoked; caller should prompt re-login"
          )

          {:error, Errors.from_response(401, resp_body, registry)}

        {:ok, 429, resp_headers, _resp_body} ->
          retry_or_give_up(
            method,
            url,
            registry,
            repository,
            extra_headers,
            body,
            ctx,
            opts,
            attempt,
            Retry.classify({:status, 429}),
            "429",
            max(Retry.retry_after_ms(resp_headers), Retry.backoff(attempt)),
            fn -> {:error, Errors.from_response(429, "Rate limited", registry)} end
          )

        {:ok, status, _resp_headers, resp_body} when status >= 500 ->
          retry_or_give_up(
            method,
            url,
            registry,
            repository,
            extra_headers,
            body,
            ctx,
            opts,
            attempt,
            Retry.classify({:status, status}),
            "#{status}",
            Retry.backoff(attempt),
            fn -> {:error, Errors.from_response(status, resp_body, registry)} end
          )

        {:ok, status, resp_headers, resp_body} ->
          {:ok, status, resp_headers, resp_body}

        # SSRF/DNS validation failure — the URL is blocked; never retry.
        {:error, reason} when is_binary(reason) ->
          Logger.error("[Compendium.OCI.Transport] Blocked request to #{registry}: #{reason}")
          {:error, Errors.connection_error(registry, reason)}

        {:error, reason} ->
          retry_or_give_up(
            method,
            url,
            registry,
            repository,
            extra_headers,
            body,
            ctx,
            opts,
            attempt,
            Retry.classify({:error, reason}),
            Errors.to_log_string(Errors.connection_error(registry, reason)),
            Retry.backoff(attempt),
            fn -> {:error, Errors.connection_error(registry, reason)} end
          )
      end
    end
  end

  # The loop's shared tail; the decision is `Compendium.Transport.Retry`'s.
  # An ambiguous failure on a non-idempotent method is not replayed — the
  # server may have acted, and even the zero-byte upload-session POST gains
  # nothing from a duplicate session.
  defp retry_or_give_up(
         method,
         url,
         registry,
         repository,
         extra_headers,
         body,
         ctx,
         opts,
         attempt,
         disposition,
         why,
         delay,
         give_up
       ) do
    cond do
      # A :never disposition (oversized response, policy refusal) is a
      # decision — replaying it downloads or refuses the same thing again.
      disposition == :never ->
        Logger.error("[Compendium.OCI.Transport] #{registry}: #{why} — not retryable")
        give_up.()

      attempt + 1 >= @max_retries ->
        Logger.error(
          "[Compendium.OCI.Transport] #{registry}: #{why} on final attempt — giving up"
        )

        give_up.()

      disposition == :retry_if_idempotent and not Retry.idempotent?(method) ->
        Logger.error(
          "[Compendium.OCI.Transport] #{registry}: #{why} for #{method} — not retrying: " <>
            "the server may have acted on it"
        )

        give_up.()

      true ->
        Logger.warning(
          "[Compendium.OCI.Transport] #{registry}: #{why}, retrying in #{delay}ms " <>
            "(attempt #{attempt + 1}/#{@max_retries})"
        )

        Process.sleep(delay)

        do_request_with_retry(
          method,
          url,
          registry,
          repository,
          extra_headers,
          body,
          ctx,
          opts,
          attempt + 1
        )
    end
  end

  # OCI repository paths look like "{namespace}/{rest}", e.g.
  # "alice/catalysts/foo" or "stripe.com/catalysts/widget". The first path
  # segment is the namespace slug we use to scope credential lookup.
  defp namespace_from_repository(repository) when is_binary(repository) do
    case String.split(repository, "/", parts: 2) do
      [slug | _] when slug != "" -> slug
      _ -> ""
    end
  end

  defp namespace_from_repository(_), do: ""
end
