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

  Follows the same pattern as `cyfr:secrets/read` (see `runtime.ex:267-291`).
  The host function is registered as a Wasmex import that the WASM component
  calls synchronously. All edge checks happen before any network I/O.

  ## Usage

      imports = Opus.HttpHandler.build_http_imports(edge, limits, ctx, "my-catalyst")
      # Merge with other imports and pass to Wasmex.Components.start_link
  """

  require Logger
  import Bitwise

  alias Sanctum.Authority.Blob.Edge
  alias Sanctum.Context
  alias Sanctum.Limits
  alias Sanctum.Policy.Enforcement
  alias Opus.EdgeGuard

  # Private IP ranges (CIDR notation as {base, mask} tuples)
  @private_ranges [
    # 127.0.0.0/8 - loopback
    {bsl(127, 24), 0xFF000000},
    # 10.0.0.0/8 - private class A
    {bsl(10, 24), 0xFF000000},
    # 172.16.0.0/12 - private class B
    {bsl(172, 24) + bsl(16, 16), 0xFFF00000},
    # 192.168.0.0/16 - private class C
    {bsl(192, 24) + bsl(168, 16), 0xFFFF0000},
    # 169.254.0.0/16 - link-local / AWS metadata
    {bsl(169, 24) + bsl(254, 16), 0xFFFF0000},
    # 0.0.0.0/8 - current network
    {0, 0xFF000000}
  ]

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
    with {:ok, request} <- parse_request(json_request),
         :ok <- validate_method(edge, request.method),
         :ok <- validate_scheme(edge, request.url),
         :ok <- validate_domain(edge, request.url),
         {:ok, request} <- decode_request_body(request),
         :ok <- EdgeGuard.check_request_size(limits, request),
         {:ok, ip} <- resolve_and_validate_ip(request.hostname, edge) do
      perform_request(request, ip, limits, component_ref, ctx)
    else
      {:error, type, message} ->
        record_egress_denial(ctx, component_ref, type, message)
        encode_error(type, message)
    end
  end

  # Audit policy-driven egress denials. DNS/transport failures are not policy
  # decisions and are skipped. Public so HttpStreamHandler's duplicate egress
  # checks share the same audit mapping.
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
        _ -> nil
      end

    if event_type do
      Enforcement.record(%{
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

  DNS resolves once, then the IP is checked against private ranges.
  Returns `{:ok, ip_string}` for public IPs or `{:error, type, message}`.

  When an edge is provided as the second argument, private IPs listed in
  its `egress.private_ips` are permitted (except `169.254.0.0/16` which is
  always blocked). A nil edge denies every private IP.
  """
  @spec resolve_and_validate_ip(String.t(), Edge.t() | nil) ::
          {:ok, String.t()} | {:error, atom(), String.t()}
  def resolve_and_validate_ip(hostname, edge \\ nil) do
    hostname_charlist = String.to_charlist(hostname)

    # Try IPv4 first, then fall back to IPv6
    case :inet.getaddr(hostname_charlist, :inet) do
      {:ok, ip_tuple} ->
        validate_resolved_ip(ip_tuple, hostname, edge)

      {:error, _ipv4_reason} ->
        case :inet.getaddr(hostname_charlist, :inet6) do
          {:ok, ip_tuple} ->
            validate_resolved_ip(ip_tuple, hostname, edge)

          {:error, reason} ->
            {:error, :dns_error, "DNS resolution failed for #{hostname}: #{inspect(reason)}"}
        end
    end
  end

  defp validate_resolved_ip(ip_tuple, hostname, edge) do
    if private_ip?(ip_tuple) do
      # Check if the edge allows this specific private IP
      if EdgeGuard.allows_private_ip?(edge, ip_tuple) do
        {:ok, :inet.ntoa(ip_tuple) |> to_string()}
      else
        {:error, :private_ip_blocked,
         "Connection to private IP #{:inet.ntoa(ip_tuple)} blocked (resolved from #{hostname})"}
      end
    else
      {:ok, :inet.ntoa(ip_tuple) |> to_string()}
    end
  end

  @doc """
  Check if an IP tuple is in a private/reserved range.

  ## IPv4
  Blocks: 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16,
  169.254.0.0/16 (link-local/AWS metadata), 0.0.0.0/8.

  ## IPv6
  Blocks: ::1 (loopback), fc00::/7 (unique local), fe80::/10 (link-local),
  :: (unspecified).
  """
  @spec private_ip?(:inet.ip4_address() | :inet.ip6_address()) :: boolean()
  def private_ip?({a, b, c, d}) do
    ip_int = bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d

    Enum.any?(@private_ranges, fn {base, mask} ->
      band(ip_int, mask) == base
    end)
  end

  # IPv6 loopback ::1
  def private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  # IPv6 unspecified ::
  def private_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true

  # IPv6 unique local fc00::/7 — first 7 bits are 1111110
  # First 16-bit group: fc00-fdff
  def private_ip?({w1, _, _, _, _, _, _, _}) when w1 >= 0xFC00 and w1 <= 0xFDFF, do: true

  # IPv6 link-local fe80::/10 — first 10 bits are 1111111010
  # First 16-bit group: fe80-febf
  def private_ip?({w1, _, _, _, _, _, _, _}) when w1 >= 0xFE80 and w1 <= 0xFEBF, do: true

  # IPv4-mapped IPv6 (::ffff:x.x.x.x) — delegate to IPv4 check
  def private_ip?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    private_ip?({bsr(ab, 8), band(ab, 0xFF), bsr(cd, 8), band(cd, 0xFF)})
  end

  # All other IPv6 addresses are considered public
  def private_ip?({_, _, _, _, _, _, _, _}), do: false

  # ============================================================================
  # Private: Request Parsing
  # ============================================================================

  defp parse_request(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"method" => method, "url" => url} = req} ->
        uri = URI.parse(url)
        hostname = uri.host

        if is_nil(hostname) or hostname == "" do
          {:error, :http_error, "Invalid URL: missing hostname"}
        else
          multipart = parse_multipart(req["multipart"])
          body = req["body"] || ""

          # Body and multipart are mutually exclusive
          if multipart != nil and body != "" do
            {:error, :http_error, "Request cannot have both 'body' and 'multipart'"}
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
        {:error, :http_error, "Invalid request: must include 'method' and 'url'"}

      {:error, _} ->
        {:error, :http_error, "Invalid JSON request"}
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

  # Decode base64 body if body_encoding is "base64", and decode multipart
  # binary parts. Returns {:ok, updated_request} or {:error, type, message}.
  defp decode_request_body(%{multipart: parts} = request) when is_list(parts) do
    case decode_multipart_parts(parts) do
      {:ok, decoded_parts} ->
        {:ok, %{request | multipart: decoded_parts}}

      {:error, message} ->
        {:error, :http_error, message}
    end
  end

  defp decode_request_body(%{body_encoding: "base64", body: body} = request)
       when is_binary(body) and body != "" do
    case Base.decode64(body) do
      {:ok, decoded} ->
        {:ok, %{request | body: decoded, body_encoding: "decoded"}}

      :error ->
        {:error, :http_error, "Invalid base64 in request body"}
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

  # ============================================================================
  # Private: HTTP Execution
  # ============================================================================

  defp perform_request(request, ip_string, limits, component_ref, ctx) do
    case parse_method_atom(request.method) do
      {:error, message} ->
        record_egress_denial(ctx, component_ref, :method_blocked, message)
        encode_error(:method_blocked, message)

      {:ok, method_atom} ->
        start_time = System.monotonic_time(:millisecond)

        req_opts = build_req_opts(request, method_atom, ip_string, limits)

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
  end

  # Node limits are validated when the blob parses, so the fallback only
  # fires for a hand-built Limits in a test.
  defp request_timeout(limits) do
    case Limits.timeout_ms(limits) do
      {:ok, ms} ->
        ms

      {:error, reason} ->
        Logger.warning(
          "[Opus.HttpHandler] Invalid timeout in node limits: #{reason}. " <>
            "Falling back to #{@request_timeout}ms."
        )

        @request_timeout
    end
  end

  defp build_req_opts(request, method_atom, ip_string, limits) do
    timeout = request_timeout(limits)

    # Pin the connection to the IP validated in execute/4 by substituting it for
    # the hostname in the URL, while preserving the original hostname for TLS
    # SNI / certificate verification / the Host header (Mint's :hostname connect
    # option). This closes the DNS-rebinding TOCTOU gap that re-resolving
    # request.url would reopen, and — because SNI/Host are preserved — does not
    # break CDN routing (which only rejects bare-IP connections that drop SNI).
    uri = URI.parse(request.url)
    pinned_url = URI.to_string(%{uri | host: Cyfr.Network.bracket_ip(ip_string)})

    base_opts = [
      method: method_atom,
      url: pinned_url,
      headers: request.headers,
      redirect: false,
      receive_timeout: timeout,
      connect_options: [hostname: uri.host, protocols: [:http1]]
    ]

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

  @valid_http_methods %{
    "GET" => :get,
    "POST" => :post,
    "PUT" => :put,
    "DELETE" => :delete,
    "PATCH" => :patch,
    "HEAD" => :head,
    "OPTIONS" => :options
  }

  defp parse_method_atom(method) do
    case Map.fetch(@valid_http_methods, method) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, "Unsupported HTTP method: #{method}"}
    end
  end

  # ============================================================================
  # Private: Response Encoding
  # ============================================================================

  defp safe_encode(data) do
    case Jason.encode(data) do
      {:ok, json} -> json
      {:error, _} -> ~s({"error":{"type":"encoding_error","message":"Failed to encode response"}})
    end
  end

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
  def encode_error(type, message) do
    safe_encode(%{
      "error" => %{
        "type" => to_string(type),
        "message" => message
      }
    })
  end

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

  defp emit_telemetry(component_ref, request, status, duration_ms) do
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
