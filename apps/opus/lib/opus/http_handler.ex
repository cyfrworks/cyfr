defmodule Opus.HttpHandler do
  @moduledoc """
  Host function HTTP handler for WASM components.

  Provides a `cyfr:http/fetch` WASI host function import that replaces the
  TCP HTTP proxy. The host receives the full structured request (method, URL,
  headers, body) before any network call, enabling complete enforcement for
  both HTTP and HTTPS.

  ## Security Properties

  - **SSRF Prevention**: DNS resolves once, IP validated against private ranges,
    then connection pinned to validated IP (no TOCTOU gap)
  - **Full Request Visibility**: Unlike a CONNECT tunnel, the host sees method,
    URL, headers, and body for both HTTP and HTTPS
  - **Size Enforcement**: Request and response bodies validated against policy limits
  - **Redirect Prevention**: `redirect: false` prevents redirect-based SSRF

  ## Architecture

  Follows the same pattern as `cyfr:secrets/read` (see `runtime.ex:267-291`).
  The host function is registered as a Wasmex import that the WASM component
  calls synchronously. All policy checks happen before any network I/O.

  ## Usage

      imports = Opus.HttpHandler.build_http_imports(policy, ctx, "my-catalyst")
      # Merge with other imports and pass to Wasmex.Components.start_link
  """

  require Logger
  import Bitwise

  alias Sanctum.{Context, Policy}
  alias Opus.PolicyEnforcer

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
  validates the request against policy and executes it.

  ## Parameters

  - `policy` - The `Sanctum.Policy` struct to enforce
  - `ctx` - The execution `Sanctum.Context`
  - `component_ref` - Component reference string for telemetry/audit

  ## Returns

  A map with the `"cyfr:http/fetch"` namespace containing a `"request"` function.
  """
  @spec build_http_imports(Policy.t(), Context.t(), String.t()) :: map()
  def build_http_imports(%Policy{} = policy, %Context{} = ctx, component_ref) do
    %{
      "cyfr:http/fetch@0.1.0" => %{
        "request" => {:fn, fn json_req ->
          execute(json_req, policy, ctx, component_ref)
        end}
      }
    }
  end

  @doc """
  Execute an HTTP request with full policy enforcement.

  Parses the JSON request, validates against policy, resolves DNS with
  private IP blocking, and executes via Req with IP pinning.

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
  @spec execute(String.t(), Policy.t(), Context.t(), String.t()) :: String.t()
  def execute(json_request, %Policy{} = policy, %Context{} = ctx, component_ref) do
    with {:ok, request} <- parse_request(json_request),
         :ok <- validate_method(policy, request.method),
         :ok <- validate_domain(policy, request.url),
         {:ok, request} <- decode_request_body(request),
         :ok <- validate_request_size(policy, request),
         :ok <- check_rate_limit(policy, ctx, component_ref),
         {:ok, ip} <- resolve_and_validate_ip(request.hostname) do
      perform_request(request, ip, policy, component_ref)
    else
      {:error, type, message} ->
        encode_error(type, message)
    end
  end

  @doc """
  Resolve hostname to IP and validate it is not a private address.

  DNS resolves once, then the IP is checked against private ranges.
  Returns `{:ok, ip_string}` for public IPs or `{:error, type, message}`.
  """
  @spec resolve_and_validate_ip(String.t()) :: {:ok, String.t()} | {:error, atom(), String.t()}
  def resolve_and_validate_ip(hostname) do
    hostname_charlist = String.to_charlist(hostname)

    # Try IPv4 first, then fall back to IPv6
    case :inet.getaddr(hostname_charlist, :inet) do
      {:ok, ip_tuple} ->
        validate_resolved_ip(ip_tuple, hostname)

      {:error, _ipv4_reason} ->
        case :inet.getaddr(hostname_charlist, :inet6) do
          {:ok, ip_tuple} ->
            validate_resolved_ip(ip_tuple, hostname)

          {:error, reason} ->
            {:error, :dns_error, "DNS resolution failed for #{hostname}: #{inspect(reason)}"}
        end
    end
  end

  defp validate_resolved_ip(ip_tuple, hostname) do
    if private_ip?(ip_tuple) do
      {:error, :private_ip_blocked,
       "Connection to private IP #{:inet.ntoa(ip_tuple)} blocked (resolved from #{hostname})"}
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

  defp decode_request_body(%{body_encoding: "base64", body: body} = request) when is_binary(body) and body != "" do
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
        {:ok, %{
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
  # Private: Policy Validation
  # ============================================================================

  defp validate_domain(policy, url) do
    uri = URI.parse(url)
    domain = uri.host || ""

    case PolicyEnforcer.check_domain(policy, domain) do
      :ok -> :ok
      {:error, msg} -> {:error, :domain_blocked, msg}
    end
  end

  defp validate_method(policy, method) do
    case PolicyEnforcer.check_method(policy, method) do
      :ok -> :ok
      {:error, msg} -> {:error, :method_blocked, msg}
    end
  end

  defp validate_request_size(policy, %{multipart: parts}) when is_list(parts) do
    size = Enum.reduce(parts, 0, fn part, acc ->
      acc + multipart_part_size(part)
    end)

    if size > policy.max_request_size do
      {:error, :request_too_large,
       "Multipart body (#{size} bytes) exceeds limit (#{policy.max_request_size} bytes)"}
    else
      :ok
    end
  end

  defp validate_request_size(policy, %{body: body}) do
    size = byte_size(body || "")

    if size > policy.max_request_size do
      {:error, :request_too_large,
       "Request body (#{size} bytes) exceeds limit (#{policy.max_request_size} bytes)"}
    else
      :ok
    end
  end

  defp multipart_part_size(%{data: data}) when is_binary(data), do: byte_size(data)
  defp multipart_part_size(%{value: value}) when is_binary(value), do: byte_size(value)
  defp multipart_part_size(_), do: 0

  defp validate_response_size(policy, body) do
    size = byte_size(body || "")

    if size > policy.max_response_size do
      {:error, :response_too_large,
       "Response body (#{size} bytes) exceeds limit (#{policy.max_response_size} bytes)"}
    else
      :ok
    end
  end

  defp check_rate_limit(policy, ctx, component_ref) do
    case Policy.check_rate_limit(policy, ctx, component_ref) do
      {:ok, _remaining} ->
        :ok

      {:error, :rate_limited, retry_after} ->
        {:error, :rate_limited,
         "Rate limit exceeded. Retry after #{div(retry_after, 1000)}s"}
    end
  end

  # ============================================================================
  # Private: HTTP Execution
  # ============================================================================

  defp perform_request(request, ip_string, policy, component_ref) do
    case parse_method_atom(request.method) do
      {:error, message} ->
        encode_error(:method_blocked, message)

      {:ok, method_atom} ->
        start_time = System.monotonic_time(:millisecond)

        req_opts = build_req_opts(request, method_atom, ip_string, policy)

        case Req.request(req_opts) do
          {:ok, response} ->
            duration_ms = System.monotonic_time(:millisecond) - start_time
            response_body = normalize_response_body(response.body)

            case validate_response_size(policy, response_body) do
              :ok ->
                emit_telemetry(component_ref, request, response.status, duration_ms)

                if request.response_encoding == "base64" do
                  encode_response_base64(response.status, response.headers, response_body)
                else
                  encode_response(response.status, response.headers, response_body)
                end

              {:error, type, message} ->
                emit_telemetry(component_ref, request, :response_too_large, duration_ms)
                encode_error(type, message)
            end

          {:error, %Req.TransportError{reason: :timeout}} ->
            duration_ms = System.monotonic_time(:millisecond) - start_time
            timeout = Policy.timeout_ms(policy) || @request_timeout
            emit_telemetry(component_ref, request, :timeout, duration_ms)
            encode_error(:timeout, "HTTP request timed out after #{timeout}ms")

          {:error, exception} ->
            duration_ms = System.monotonic_time(:millisecond) - start_time
            emit_telemetry(component_ref, request, :error, duration_ms)
            encode_error(:http_error, "HTTP request failed: #{Exception.message(exception)}")
        end
    end
  end

  defp build_req_opts(request, method_atom, _ip_string, policy) do
    # Note: We validated DNS resolves to a public IP (SSRF protection) in execute/4
    # but do NOT pin the connection to that IP, as IP pinning breaks CDN routing
    # (e.g. Cloudflare returns 403 when connected by IP directly).
    timeout = Policy.timeout_ms(policy) || @request_timeout
    base_opts = [
      method: method_atom,
      url: request.url,
      headers: request.headers,
      redirect: false,
      receive_timeout: timeout
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
        file_opts = if content_type, do: [{:content_type, content_type} | file_opts], else: file_opts
        {name, {data, file_opts}}

      %{name: name, value: value} ->
        {name, value}
    end)
  end

  defp normalize_response_body(nil), do: ""
  defp normalize_response_body(body) when is_binary(body), do: body
  defp normalize_response_body(body) when is_map(body) or is_list(body), do: Jason.encode!(body)
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

  @doc false
  def encode_response(status, headers, body) do
    response_headers =
      headers
      |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
      |> Map.new()

    body_str = if is_binary(body), do: body, else: to_string(body)
    body_str = ensure_utf8(body_str)

    Jason.encode!(%{
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

    Jason.encode!(%{
      "status" => status,
      "headers" => response_headers,
      "body" => Base.encode64(body_binary),
      "body_encoding" => "base64"
    })
  end

  @doc false
  def encode_error(type, message) do
    Jason.encode!(%{
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
        result when is_binary(result) -> result
        _ ->
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
