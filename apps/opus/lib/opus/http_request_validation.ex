# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HttpRequestValidation do
  @moduledoc """
  Shared pre-flight validation for the guest-facing HTTP host functions.

  `Opus.HttpHandler` (`cyfr:http/fetch`) and `Opus.HttpStreamHandler`
  (`cyfr:http/streaming`) sit on the same trust boundary and must enforce the
  same checks in the same order. This module is the single path both go
  through before any network I/O:

      parse → method → scheme → domain → body decode → request size →
      egress rate limit → DNS resolve + private-IP validation → method atom

  The resolve→validate→pin sequence itself lives in `Cyfr.Network.pin/2` —
  neither the range table nor the DNS ladder nor the pinned transport
  policy is duplicated here or in the handlers; this module contributes
  only the consent policy (`egress.private_ips` via `Opus.EdgeGuard`).

  `validate/6` returns a validated request map (including the pinned IP and
  the Req method atom) that each handler then executes its own way (buffered
  fetch vs. polling stream). Handlers own transport, response handling, and
  telemetry; every pre-flight decision lives here.
  """

  require Logger

  alias Opus.EdgeGuard
  alias Sanctum.Authority.Blob.Edge
  alias Sanctum.Context
  alias Sanctum.Limits

  @valid_http_methods %{
    "GET" => :get,
    "POST" => :post,
    "PUT" => :put,
    "DELETE" => :delete,
    "PATCH" => :patch,
    "HEAD" => :head,
    "OPTIONS" => :options
  }

  @type validated_request :: %{
          method: String.t(),
          method_atom: atom(),
          url: String.t(),
          hostname: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary(),
          body_encoding: String.t() | nil,
          response_encoding: String.t() | nil,
          multipart: list() | nil,
          ip: String.t(),
          pin_req_opts: keyword()
        }

  @doc """
  Parse and validate a guest HTTP request against the consent edge and node
  limits, resolving DNS once and pinning the validated IP.

  Returns `{:ok, validated_request}` with `:ip` (validated IP string) and
  `:method_atom` (Req method) added, or `{:error, type, message}`.

  ## Options

    * `:allow_multipart` — `false` rejects requests carrying a `multipart`
      field (the streaming transport cannot send one). Defaults to `true`.
  """
  @spec validate(String.t(), Edge.t() | nil, Limits.t(), Context.t(), String.t(), keyword()) ::
          {:ok, validated_request()} | {:error, atom(), String.t()}
  def validate(json_request, edge, %Limits{} = limits, %Context{} = ctx, component_ref, opts \\ []) do
    with {:ok, request} <- parse_request(json_request),
         :ok <- validate_method(edge, request.method),
         :ok <- validate_scheme(edge, request.url),
         :ok <- validate_domain(edge, request.url),
         :ok <- check_multipart_allowed(request, Keyword.get(opts, :allow_multipart, true)),
         {:ok, request} <- decode_request_body(request),
         :ok <- EdgeGuard.check_request_size(limits, request),
         :ok <- check_egress_rate(ctx, component_ref, limits),
         {:ok, pin} <- pin_url(request.url, edge),
         {:ok, method_atom} <- validated_method_atom(request.method) do
      {:ok,
       request
       |> Map.put(:ip, pin.ip)
       |> Map.put(:pin_req_opts, pin.req_opts)
       |> Map.put(:method_atom, method_atom)}
    end
  end

  # The one resolve→validate→pin call, with the guest's consent policy
  # closed over the edge. `pin_req_opts` carries the pinned URL and the
  # full fail-closed transport policy — before this the handlers rebuilt
  # their own Req options and silently inherited Req's auto-retry (one
  # fetch could become four wire requests, invisible to the rate limiter)
  # and auto-decode (response size measured on re-encoded bytes).
  defp pin_url(url, edge) do
    case Cyfr.Network.pin(url,
           private_policy: {:fun, &EdgeGuard.allows_private_ip?(edge, &1)},
           protocols: [:http1]
         ) do
      {:ok, pin} -> {:ok, pin}
      {:error, :invalid_url, message} -> {:error, :invalid_request, message}
      {:error, type, message} -> {:error, type, message}
    end
  end

  # The consented rate limit, on the wire-bound path itself — the WIT
  # contract promises the host enforces rate limits before executing the
  # request, and until this step only the per-invocation gate existed, so
  # one invocation could issue unbounded egress. Keyed per component like
  # the executor's gate (a distinct "http:" budget under the same
  # consented config); before DNS, so a denied caller cannot use the
  # resolver either. A dead limiter fails CLOSED, matching the executor.
  defp check_egress_rate(%Context{} = ctx, component_ref, %Limits{} = limits) do
    case Opus.RateLimiter.check(ctx.athanor_id, "http:" <> component_ref, %{
           rate_limit: limits.rate_limit
         }) do
      {:ok, _remaining} ->
        :ok

      {:error, :rate_limited, retry_after} ->
        {:error, :rate_limited,
         "HTTP egress rate limit exceeded; retry in #{retry_after}ms"}

      {:error, :missing_tenant} ->
        {:error, :rate_limited, "HTTP egress refused: no resolved athanor"}
    end
  catch
    :exit, _reason ->
      {:error, :rate_limited, "HTTP egress refused: rate limiter unavailable"}
  end

  @doc """
  Resolve a hostname to a validated IP under the edge's consent policy.

  A thin wrapper over `Cyfr.Network.pin/2` kept for callers that want the
  IP alone; `validate/6` pins the whole request. Private IPs listed in the
  edge's `egress.private_ips` are permitted (except `169.254.0.0/16`,
  always blocked); a nil edge denies every private IP.
  """
  @spec resolve_and_validate_ip(String.t(), Edge.t() | nil) ::
          {:ok, String.t()} | {:error, atom(), String.t()}
  def resolve_and_validate_ip(hostname, edge \\ nil) do
    case pin_url("https://" <> hostname, edge) do
      {:ok, %{ip: ip}} -> {:ok, ip}
      {:error, type, message} -> {:error, type, message}
    end
  end

  @doc """
  The node's consented timeout in milliseconds.

  Node limits are validated when the blob parses, so the fallback only
  fires for a hand-built Limits in a test.
  """
  @spec timeout_ms(Limits.t(), non_neg_integer()) :: non_neg_integer()
  def timeout_ms(%Limits{} = limits, fallback_ms) do
    case Limits.timeout_ms(limits) do
      {:ok, ms} ->
        ms

      {:error, reason} ->
        Logger.warning(
          "[Opus.HttpRequestValidation] Invalid timeout in node limits: #{reason}. " <>
            "Falling back to #{fallback_ms}ms."
        )

        fallback_ms
    end
  end

  # ============================================================================
  # Private: Request Parsing
  # ============================================================================

  defp parse_request(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"method" => method, "url" => url} = req} ->
        uri = URI.parse(url)
        hostname = uri.host

        if is_nil(hostname) or hostname == "" do
          {:error, :invalid_request, "Invalid URL: missing hostname"}
        else
          multipart = parse_multipart(req["multipart"])
          body = req["body"] || ""

          # Body and multipart are mutually exclusive
          if multipart != nil and body != "" do
            {:error, :invalid_request, "Request cannot have both 'body' and 'multipart'"}
          else
            {:ok,
             %{
               method: String.upcase(method),
               url: url,
               hostname: hostname,
               headers: parse_headers(req["headers"]),
               body: body,
               body_encoding: req["body_encoding"],
               response_encoding: req["response_encoding"],
               multipart: multipart
             }}
          end
        end

      {:ok, _} ->
        {:error, :invalid_request, "Invalid request: must include 'method' and 'url'"}

      {:error, _} ->
        {:error, :invalid_json, "Invalid JSON request"}
    end
  end

  defp parse_headers(nil), do: []

  defp parse_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp parse_headers(headers) when is_list(headers), do: headers
  defp parse_headers(_), do: []

  defp parse_multipart(nil), do: nil
  defp parse_multipart(parts) when is_list(parts), do: parts
  defp parse_multipart(_), do: nil

  # The streaming transport cannot send multipart bodies; rejecting loudly
  # beats silently dropping the parts.
  defp check_multipart_allowed(%{multipart: parts}, false) when is_list(parts) do
    {:error, :invalid_request, "Streaming requests do not support 'multipart'"}
  end

  defp check_multipart_allowed(_request, _allow), do: :ok

  # Decode base64 body if body_encoding is "base64", and decode multipart
  # binary parts. Returns {:ok, updated_request} or {:error, type, message}.
  # Decoding happens before the size check so limits apply to the raw bytes
  # that would go on the wire, not the base64 inflation.
  defp decode_request_body(%{multipart: parts} = request) when is_list(parts) do
    case decode_multipart_parts(parts) do
      {:ok, decoded_parts} ->
        {:ok, %{request | multipart: decoded_parts}}

      {:error, message} ->
        {:error, :invalid_request, message}
    end
  end

  defp decode_request_body(%{body_encoding: "base64", body: body} = request)
       when is_binary(body) and body != "" do
    case Base.decode64(body) do
      {:ok, decoded} ->
        {:ok, %{request | body: decoded, body_encoding: "decoded"}}

      :error ->
        {:error, :invalid_request, "Invalid base64 in request body"}
    end
  end

  defp decode_request_body(request), do: {:ok, request}

  # Decode multipart parts: base64-encoded "data" fields become raw binary
  defp decode_multipart_parts(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
      case decode_multipart_part(part) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, msg} -> {:halt, {:error, msg}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_multipart_part(%{"name" => name, "data" => data} = part) when is_binary(data) do
    case Base.decode64(data) do
      {:ok, decoded} ->
        {:ok,
         %{
           name: name,
           data: decoded,
           filename: part["filename"],
           content_type: part["content_type"]
         }}

      :error ->
        {:error, "Invalid base64 in multipart part '#{name}'"}
    end
  end

  defp decode_multipart_part(%{"name" => name, "value" => value}) do
    {:ok, %{name: name, value: to_string(value)}}
  end

  defp decode_multipart_part(%{"name" => name}) do
    {:ok, %{name: name, value: ""}}
  end

  defp decode_multipart_part(_) do
    {:error, "Multipart part must include 'name' and either 'data' or 'value'"}
  end

  # ============================================================================
  # Private: Edge Validation
  # ============================================================================

  defp validate_domain(edge, url) do
    uri = URI.parse(url)
    domain = uri.host || ""

    case EdgeGuard.check_domain(edge, domain) do
      :ok -> :ok
      {:error, msg} -> {:error, :domain_blocked, msg}
    end
  end

  defp validate_scheme(edge, url) do
    scheme = URI.parse(url).scheme || ""

    case EdgeGuard.check_scheme(edge, scheme) do
      :ok -> :ok
      {:error, msg} -> {:error, :scheme_blocked, msg}
    end
  end

  defp validate_method(edge, method) do
    case EdgeGuard.check_method(edge, method) do
      :ok -> :ok
      {:error, msg} -> {:error, :method_blocked, msg}
    end
  end

  # The edge allowlist check (validate_method/2) runs first; this maps the
  # allowed method string to the Req atom and rejects anything outside the
  # supported verb set. Runs after DNS resolution to preserve the handlers'
  # historical error precedence.
  defp validated_method_atom(method) do
    case Map.fetch(@valid_http_methods, method) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :method_blocked, "Unsupported HTTP method: #{method}"}
    end
  end

end
