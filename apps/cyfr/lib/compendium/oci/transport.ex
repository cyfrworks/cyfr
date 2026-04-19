defmodule Compendium.OCI.Transport do
  @moduledoc """
  HTTP transport layer for OCI Distribution API calls.

  Wraps Finch with:
  - Automatic auth header injection via `OCI.Auth`
  - Automatic 401 challenge handling (token exchange + retry)
  - Retry with exponential backoff for 5xx and timeouts (3 attempts)
  - Consistent return format: `{:ok, status, headers, body}` or `{:error, reason}`
  """

  require Logger

  alias Compendium.OCI.{Auth, Errors, Reference}

  @max_retries 3
  @base_delay_ms 500
  @receive_timeout 120_000

  @type response :: {:ok, integer(), [{String.t(), String.t()}], binary()}
  @type error :: {:error, Errors.t() | String.t()}

  @doc """
  Perform an HTTP request to an OCI registry endpoint.

  Automatically injects auth headers and handles 401 challenges.
  Retries on 5xx errors with exponential backoff.
  """
  @spec request(
          atom(),
          String.t(),
          Reference.t(),
          [{String.t(), String.t()}],
          binary() | nil,
          Sanctum.Context.t() | nil
        ) ::
          response() | error()
  def request(method, path, %Reference{} = ref, extra_headers \\ [], body \\ nil, ctx \\ nil) do
    base_url = Reference.api_base(ref)
    url = base_url <> path

    do_request_with_retry(method, url, ref.registry, ref.repository, extra_headers, body, ctx, 0)
  end

  @doc """
  Perform an HTTP request to an arbitrary URL (used for blob uploads where
  the registry may return a different location URL).
  """
  @spec request_url(
          atom(),
          String.t(),
          String.t(),
          String.t(),
          [{String.t(), String.t()}],
          binary() | nil,
          Sanctum.Context.t() | nil
        ) ::
          response() | error()
  def request_url(method, url, registry, repository, extra_headers \\ [], body \\ nil, ctx \\ nil) do
    do_request_with_retry(method, url, registry, repository, extra_headers, body, ctx, 0)
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp do_request_with_retry(_method, _url, registry, _repository, _headers, _body, _ctx, attempt)
       when attempt >= @max_retries do
    Logger.error(
      "[Compendium.OCI.Transport] All #{@max_retries} retries exhausted for #{registry}"
    )

    {:error, Errors.connection_error(registry, :max_retries_exceeded)}
  end

  defp do_request_with_retry(method, url, registry, repository, extra_headers, body, ctx, attempt) do
    namespace_slug = namespace_from_repository(repository)
    {:ok, auth_headers} = Auth.auth_headers(registry, repository, namespace_slug, ctx)
    headers = auth_headers ++ extra_headers

    finch_request = build_finch_request(method, url, headers, body)

    case Finch.request(finch_request, Compendium.Finch, receive_timeout: @receive_timeout) do
      {:ok, %Finch.Response{status: 401, headers: resp_headers, body: resp_body}} ->
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

      {:ok, %Finch.Response{status: 429, headers: resp_headers}} ->
        if attempt + 1 < @max_retries do
          retry_after = extract_retry_after(resp_headers)
          delay = max(retry_after, (@base_delay_ms * :math.pow(2, attempt)) |> round())

          Logger.warning(
            "[Compendium.OCI.Transport] #{registry} returned 429, " <>
              "retrying in #{delay}ms (attempt #{attempt + 1}/#{@max_retries})"
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
            attempt + 1
          )
        else
          Logger.error(
            "[Compendium.OCI.Transport] #{registry} returned 429 on final attempt — giving up"
          )

          {:error, Errors.from_response(429, "Rate limited", registry)}
        end

      {:ok, %Finch.Response{status: status, body: resp_body}}
      when status >= 500 ->
        if attempt + 1 < @max_retries do
          delay = (@base_delay_ms * :math.pow(2, attempt)) |> round()

          Logger.warning(
            "[Compendium.OCI.Transport] #{registry} returned #{status}, " <>
              "retrying in #{delay}ms (attempt #{attempt + 1}/#{@max_retries})"
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
            attempt + 1
          )
        else
          Logger.error(
            "[Compendium.OCI.Transport] #{registry} returned #{status} on final attempt — giving up"
          )

          {:error, Errors.from_response(status, resp_body, registry)}
        end

      {:ok, %Finch.Response{status: status, headers: resp_headers, body: resp_body}} ->
        {:ok, status, resp_headers, resp_body}

      {:error, %Mint.TransportError{} = error} ->
        if attempt + 1 < @max_retries do
          delay = (@base_delay_ms * :math.pow(2, attempt)) |> round()

          Logger.warning(
            "[Compendium.OCI.Transport] Transport error for #{registry}: #{inspect(error)}, " <>
              "retrying in #{delay}ms (attempt #{attempt + 1}/#{@max_retries})"
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
            attempt + 1
          )
        else
          Logger.error(
            "[Compendium.OCI.Transport] Transport error for #{registry}: #{inspect(error)} — giving up after #{@max_retries} attempts"
          )

          {:error, Errors.connection_error(registry, error)}
        end

      {:error, reason} ->
        if attempt + 1 < @max_retries do
          delay = (@base_delay_ms * :math.pow(2, attempt)) |> round()

          Logger.warning(
            "[Compendium.OCI.Transport] Error for #{registry}: #{inspect(reason)}, " <>
              "retrying in #{delay}ms (attempt #{attempt + 1}/#{@max_retries})"
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
            attempt + 1
          )
        else
          Logger.error(
            "[Compendium.OCI.Transport] Error for #{registry}: #{inspect(reason)} — giving up after #{@max_retries} attempts"
          )

          {:error, Errors.connection_error(registry, reason)}
        end
    end
  end

  defp extract_retry_after(headers) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, value} ->
        case Integer.parse(value) do
          {seconds, _} -> seconds * 1000
          :error -> 0
        end

      nil ->
        0
    end
  end

  defp build_finch_request(method, url, headers, nil) do
    Finch.build(method, url, headers)
  end

  defp build_finch_request(method, url, headers, body) do
    Finch.build(method, url, headers, body)
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
