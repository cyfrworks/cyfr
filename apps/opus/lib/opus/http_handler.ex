# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HttpHandler do
  @moduledoc """
  Host function HTTP handler for WASM components.

  Provides a `cyfr:http/fetch` WASI host function import that replaces the
  TCP HTTP proxy. The host receives the full structured request (method, URL,
  headers, body) before any network call, enabling complete enforcement for
  both HTTP and HTTPS.

  ## Security Properties

  - **SSRF Prevention**: DNS resolves once, IP validated against private ranges,
    then the connection is pinned to that validated IP — the original hostname
    is preserved for TLS SNI / certificate verification / the `Host` header, so
    there is no DNS-rebinding TOCTOU gap and no second resolution to rebind
  - **Full Request Visibility**: Unlike a CONNECT tunnel, the host sees method,
    URL, headers, and body for both HTTP and HTTPS
  - **Size Enforcement**: Request and response bodies validated against node limits
  - **Redirect Prevention**: `redirect: false` prevents redirect-based SSRF

  ## Architecture

  Follows the same pattern as `cyfr:vault/read` (see `runtime.ex:267-291`).
  The host function is registered as a Wasmex import that the WASM component
  calls synchronously. All edge checks happen before any network I/O via
  `Opus.HttpRequestValidation` — the single validation path shared with
  `Opus.HttpStreamHandler`. The private/reserved-IP range policy lives in
  `Cyfr.Network.private_ip?/1`.

  ## Usage

      imports = Opus.HttpHandler.build_http_imports(edge, limits, ctx, "my-catalyst")
      # Merge with other imports and pass to Wasmex.Components.start_link
  """

  require Logger

  alias Sanctum.Authority.Blob.Edge
  alias Sanctum.Context
  alias Sanctum.Limits
  alias Opus.EdgeGuard
  alias Opus.HttpRequestValidation

  @request_timeout 30_000

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Build Wasmex import map for the `cyfr:http/fetch` host function.

  Returns a map suitable for merging into `Wasmex.Components.start_link` opts.
  When the component calls `cyfr:http/fetch.request(json)`, the host function
  validates the request against the consent edge and executes it.

  ## Parameters

  - `edge` - The `Sanctum.Authority.Blob.Edge` to enforce (nil = deny all egress)
  - `limits` - The node's `Sanctum.Limits` (sizes, timeout)
  - `ctx` - The execution `Sanctum.Context`
  - `component_ref` - Component reference string for telemetry/audit

  ## Returns

  A map with the `"cyfr:http/fetch"` namespace containing a `"request"` function.
  """
  @spec build_http_imports(Edge.t() | nil, Limits.t(), Context.t(), String.t()) :: map()
  def build_http_imports(edge, %Limits{} = limits, %Context{} = ctx, component_ref) do
    %{
      "cyfr:http/fetch@0.1.0" => %{
        "request" =>
          {:fn,
           fn json_req ->
             execute(json_req, edge, limits, ctx, component_ref)
           end}
      }
    }
  end

  @doc """
  Execute an HTTP request with full edge enforcement.

  Parses the JSON request, validates against the consent edge and node
  limits, resolves DNS with private IP blocking, and executes via Req with
  IP pinning.

  ## Request Format (JSON)

      {
        "method": "GET",
        "url": "https://api.stripe.com/v1/charges",
        "headers": {"Authorization": "Bearer sk_..."},
        "body": ""
      }

  ## Extended Request Options

  ### Base64 body encoding (for sending binary data):
      {
        "method": "POST",
        "url": "...",
        "headers": {...},
        "body": "<base64 encoded data>",
        "body_encoding": "base64"
      }

  ### Base64 response encoding (for receiving binary data):
      {
        "method": "POST",
        "url": "...",
        "headers": {...},
        "body": "...",
        "response_encoding": "base64"
      }

  ### Multipart/form-data (for file uploads):
      {
        "method": "POST",
        "url": "...",
        "headers": {...},
        "multipart": [
          {"name": "file", "filename": "audio.mp3", "content_type": "audio/mpeg", "data": "<base64>"},
          {"name": "model", "value": "whisper-1"}
        ]
      }

  ## Response Format (JSON)

  On success:
      {"status": 200, "headers": {...}, "body": "..."}

  On success with base64 response encoding:
      {"status": 200, "headers": {...}, "body": "<base64>", "body_encoding": "base64"}

  On error:
      {"error": {"type": "domain_blocked", "message": "..."}}

  All errors are returned as JSON strings (never raised).
  """
  @spec execute(String.t(), Edge.t() | nil, Limits.t(), Context.t(), String.t()) :: String.t()
  def execute(json_request, edge, %Limits{} = limits, %Context{} = ctx, component_ref) do
    case HttpRequestValidation.validate(json_request, edge, limits, ctx, component_ref) do
      {:ok, request} ->
        perform_request(request, limits, component_ref, ctx)

      {:error, type, message} ->
        record_egress_denial(ctx, component_ref, type, message)
        encode_error(type, message)
    end
  end

  # Audit policy-driven egress denials. DNS/transport failures are not policy
  # decisions and are skipped. Public so HttpStreamHandler shares the same
  # audit mapping for the shared validation path.
  @doc false
  def record_egress_denial(ctx, component_ref, type, message) do
    event_type =
      case type do
        :domain_blocked -> :domain_blocked
        :method_blocked -> :method_blocked
        :scheme_blocked -> :scheme_blocked
        :request_too_large -> :request_size
        :response_too_large -> :request_size
        :private_ip_blocked -> :denied
        :rate_limited -> :denied
        _ -> nil
      end

    if event_type do
      Opus.Host.enforce(%{
        ctx: ctx,
        component_ref: component_ref,
        component_type: :catalyst,
        event_type: event_type,
        decision: :denied,
        decision_reason: message
      })
    end

    :ok
  end

  @doc """
  Resolve hostname to IP and validate it is not a private address.

  Delegates to `Opus.HttpRequestValidation.resolve_and_validate_ip/2` — the
  shared pre-flight path for both HTTP host functions.
  """
  @spec resolve_and_validate_ip(String.t(), Edge.t() | nil) ::
          {:ok, String.t()} | {:error, atom(), String.t()}
  defdelegate resolve_and_validate_ip(hostname, edge \\ nil), to: HttpRequestValidation

  @doc """
  Check if an IP tuple is in a private/reserved range.

  Delegates to `Cyfr.Network.private_ip?/1` — the single source of truth for
  the private/reserved-range egress policy. No range table lives in Opus.
  """
  @spec private_ip?(:inet.ip4_address() | :inet.ip6_address()) :: boolean()
  defdelegate private_ip?(ip_tuple), to: Cyfr.Network

  # ============================================================================
  # Private: HTTP Execution
  # ============================================================================

  defp perform_request(request, limits, component_ref, ctx) do
    start_time = System.monotonic_time(:millisecond)

    req_opts = build_req_opts(request, limits)

    case Req.request(req_opts) do
      {:ok, response} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        response_body = normalize_response_body(response.body)

        case EdgeGuard.check_response_size(limits, response_body) do
          :ok ->
            emit_telemetry(component_ref, request, response.status, duration_ms)

            if request.response_encoding == "base64" do
              encode_response_base64(response.status, response.headers, response_body)
            else
              encode_response(response.status, response.headers, response_body)
            end

          {:error, type, message} ->
            emit_telemetry(component_ref, request, :response_too_large, duration_ms)
            record_egress_denial(ctx, component_ref, type, message)
            encode_error(type, message)
        end

      {:error, %Req.TransportError{reason: :timeout}} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        emit_telemetry(component_ref, request, :timeout, duration_ms)
        encode_error(:timeout, "HTTP request timed out after #{request_timeout(limits)}ms")

      {:error, exception} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        emit_telemetry(component_ref, request, :error, duration_ms)
        encode_error(:http_error, "HTTP request failed: #{Exception.message(exception)}")
    end
  end

  defp request_timeout(limits) do
    HttpRequestValidation.timeout_ms(limits, @request_timeout)
  end

  defp build_req_opts(request, limits) do
    # The pinned URL and the fail-closed transport policy come from
    # `Cyfr.Network.pin/2` via validation (`request.pin_req_opts`) — one
    # implementation of IP pinning for both outbound planes. Rebuilding
    # options here once silently inherited Req's auto-retry and
    # auto-decode defaults, so a guest fetch could hit the wire four
    # times and its response size was measured on re-encoded bytes.
    base_opts =
      request.pin_req_opts
      |> Keyword.put(:method, request.method_atom)
      |> Keyword.put(:headers, request.headers)
      |> Keyword.put(:receive_timeout, request_timeout(limits))

    cond do
      # Multipart request
      is_list(request.multipart) ->
        multipart_fields = build_multipart_fields(request.multipart)
        Keyword.put(base_opts, :form_multipart, multipart_fields)

      # Regular body
      request.body != "" ->
        Keyword.put(base_opts, :body, request.body)

      true ->
        base_opts
    end
  end

  defp build_multipart_fields(parts) do
    Enum.map(parts, fn
      %{name: name, data: data, filename: filename, content_type: content_type} ->
        file_opts = []
        file_opts = if filename, do: [{:filename, filename} | file_opts], else: file_opts

        file_opts =
          if content_type, do: [{:content_type, content_type} | file_opts], else: file_opts

        {name, {data, file_opts}}

      %{name: name, value: value} ->
        {name, value}
    end)
  end

  defp normalize_response_body(nil), do: ""
  defp normalize_response_body(body) when is_binary(body), do: body

  defp normalize_response_body(body) when is_map(body) or is_list(body) do
    case Jason.encode(body) do
      {:ok, json} -> json
      {:error, _} -> inspect(body)
    end
  end

  defp normalize_response_body(body), do: to_string(body)

  # ============================================================================
  # Private: Response Encoding
  # ============================================================================

  defp safe_encode(data), do: Opus.WitResponse.safe_encode(data)

  @doc false
  def encode_response(status, headers, body) do
    response_headers =
      headers
      |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
      |> Map.new()

    body_str = if is_binary(body), do: body, else: to_string(body)
    body_str = ensure_utf8(body_str)

    safe_encode(%{
      "status" => status,
      "headers" => response_headers,
      "body" => body_str
    })
  end

  @doc false
  def encode_response_base64(status, headers, body) do
    response_headers =
      headers
      |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
      |> Map.new()

    body_binary = if is_binary(body), do: body, else: to_string(body)

    safe_encode(%{
      "status" => status,
      "headers" => response_headers,
      "body" => Base.encode64(body_binary),
      "body_encoding" => "base64"
    })
  end

  @doc false
  def encode_error(type, message), do: Opus.WitResponse.encode_error(type, message)

  # Replace invalid UTF-8 bytes with the Unicode replacement character (U+FFFD).
  # Some servers (e.g. japan-guide.com) return Windows-1252 or other legacy
  # encodings that would crash Jason.encode!/1.
  defp ensure_utf8(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      binary
      |> :unicode.characters_to_binary(:latin1)
      |> case do
        result when is_binary(result) ->
          Logger.debug(
            "[Opus.HttpHandler] Response contained non-UTF-8 bytes; converted from Latin-1 encoding"
          )

          result

        _ ->
          Logger.debug(
            "[Opus.HttpHandler] Response contained non-UTF-8 bytes that could not be converted from Latin-1; replacing with U+FFFD"
          )

          # Fallback: drop non-UTF-8 bytes
          for <<byte <- binary>>, into: "" do
            if byte < 128, do: <<byte>>, else: "\uFFFD"
          end
      end
    end
  end

  # ============================================================================
  # Private: Telemetry
  # ============================================================================

  @doc false
  # Shared with HttpStreamHandler so both egress paths emit one event.
  def emit_telemetry(component_ref, request, status, duration_ms) do
    :telemetry.execute(
      [:cyfr, :opus, :http, :request],
      %{duration_ms: duration_ms, system_time: System.system_time()},
      %{
        component_ref: component_ref,
        method: request.method,
        hostname: request.hostname,
        status: status
      }
    )
  end
end
