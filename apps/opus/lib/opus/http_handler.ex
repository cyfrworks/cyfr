# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HttpHandler do
  @moduledoc """
  Host function HTTP handler for WASM components.

  Provides the `cyfr:http/fetch` WASI host import. Validates the full
  request, including method, URL, headers, and body, before network I/O
  for both HTTP and HTTPS.

  ## Security Properties

  - **SSRF Prevention**: the engine resolves no name. CYFR pins the address
    each request connects to under the attempt's authority, applying its
    private-address policy (`Opus.HostClient.egress_pin/3`), and the
    connection goes to exactly that address, with the original hostname kept
    for TLS SNI / certificate verification / the `Host` header, so there is
    no DNS-rebinding gap and no second resolution to rebind. A metadata
    address is refused even when CYFR answers one (`Opus.Egress`)
  - **Full Request Visibility**: Unlike a CONNECT tunnel, the host sees method,
    URL, headers, and body for both HTTP and HTTPS
  - **Size Enforcement**: Request and response bodies validated against node limits
  - **Redirects**: `redirect: false`; a guest that follows a redirect makes
    its next hop as a request of its own, pinned from the pin the redirect
    came from, and CYFR refuses a hop to another origin; were one pinned,
    it would go without any header that carries a credential
    (`Prima.Network.strip_credentials/1`)

  ## Architecture

  Follows the same pattern as `cyfr:vault/read` (see `runtime.ex:267-291`).
  The host function is registered as a Wasmex import that the WASM component
  calls synchronously. All edge checks happen before any network I/O via
  `Opus.HttpRequestValidation` — the single validation path shared with
  `Opus.HttpStreamHandler`.

  ## Usage

      imports = Opus.HttpHandler.build_http_imports(edge, limits, host, "my-catalyst")
      # Merge with other imports and pass to Wasmex.Components.start_link
  """

  require Logger

  alias Prima.Authority.Blob.Edge
  alias Prima.Limits
  alias Opus.EdgeGuard
  alias Opus.HostClient
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

  - `edge` - The `Prima.Authority.Blob.Edge` to enforce (nil = deny all egress)
  - `limits` - The node's `Prima.Limits` (sizes, timeout)
  - `host` - The attached `Opus.HostClient` of the execution's attempt,
    which takes each request from the consented rate and records each
    refusal for the audit trail
  - `component_ref` - Component reference string for telemetry/audit

  ## Returns

  A map with the `"cyfr:http/fetch"` namespace containing a `"request"` function.
  """
  @spec build_http_imports(Edge.t() | nil, Limits.t(), HostClient.t(), String.t()) :: map()
  def build_http_imports(edge, %Limits{} = limits, %HostClient{} = host, component_ref) do
    %{
      "cyfr:http/fetch@0.1.0" => %{
        "request" =>
          {:fn, fn json_req -> execute(json_req, edge, limits, host, component_ref) end}
      }
    }
  end

  @doc """
  Execute an HTTP request with full edge enforcement.

  Parses the JSON request, validates it against the consent edge and node
  limits, pins its address through CYFR and executes it via Req connected
  to that address. A redirecting answer (`3xx` with a `Location`) is
  answered to the guest as it is, and a request the guest then makes to
  where it points is the redirect's next hop (`Opus.Egress.redirected/4`).

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
  @spec execute(String.t(), Edge.t() | nil, Limits.t(), HostClient.t(), String.t()) :: String.t()
  def execute(json_request, edge, %Limits{} = limits, %HostClient{} = host, component_ref) do
    do_execute(json_request, edge, limits, host, component_ref)
  rescue
    # The guest controls this JSON; a raise below here would take the
    # Wasmex process with it. The message stays generic and the exception
    # goes to the host log.
    exception ->
      Logger.error(
        "[Opus.HttpHandler] #{component_ref} request raised: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      encode_error(:invalid_request, "Malformed HTTP request.")
  end

  defp do_execute(json_request, edge, limits, host, component_ref) do
    case HttpRequestValidation.validate(json_request, edge, limits, host, component_ref) do
      {:ok, request} ->
        perform_request(request, limits, component_ref, host)

      {:error, type, message} ->
        record_refusal(host, type, message)
        encode_error(type, message)

      # CYFR refused the pin, and has already recorded the denial.
      {:refused, type, message} ->
        encode_error(type, message)
    end
  end

  @doc false
  # Report a refusal of the egress checks to CYFR, which records the policy
  # decisions among them for the audit trail
  # (`Opus.HostClient.record_denial/3`). A request that was made and failed
  # is not a refusal. Shared with `Opus.HttpStreamHandler`.
  @spec record_refusal(HostClient.t(), atom(), String.t()) :: :ok
  def record_refusal(%HostClient{} = host, type, message) when is_atom(type) do
    _ = HostClient.record_denial(host, Atom.to_string(type), message)
    :ok
  end

  # ============================================================================
  # Private: HTTP Execution
  # ============================================================================

  defp perform_request(request, limits, component_ref, host) do
    start_time = System.monotonic_time(:millisecond)

    # The response ceiling is enforced WHILE the body streams in — the
    # collector aborts the transfer at the limit, so a hostile server on
    # an allowed domain cannot make the host buffer an arbitrarily large
    # binary before the check runs.
    max_bytes = limits.max_response_size

    req_opts =
      request
      |> build_req_opts(limits)
      |> Keyword.put(:into, Prima.BoundedBody.collector(max_bytes))

    case Req.request(req_opts) do
      {:ok, response} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        case Prima.BoundedBody.read(response, max_bytes) do
          {:ok, body} ->
            response_body = normalize_response_body(body)

            case EdgeGuard.check_response_size(limits, response_body) do
              :ok ->
                emit_telemetry(component_ref, request, response.status, duration_ms)
                note_redirect(host, request, response)

                if request.response_encoding == "base64" do
                  encode_response_base64(response.status, response.headers, response_body)
                else
                  encode_response(response.status, response.headers, response_body)
                end

              {:error, type, message} ->
                emit_telemetry(component_ref, request, :response_too_large, duration_ms)
                record_refusal(host, type, message)
                encode_error(type, message)
            end

          {:error, {:response_too_large, size, _max}} ->
            {:error, type, message} = EdgeGuard.check_response_bytes(limits, size)
            emit_telemetry(component_ref, request, :response_too_large, duration_ms)
            record_refusal(host, type, message)
            encode_error(type, message)
        end

      {:error, %Req.TransportError{reason: :timeout}} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        emit_telemetry(component_ref, request, :timeout, duration_ms)
        encode_error(:timeout, "HTTP request timed out after #{request_timeout(limits)}ms")

      {:error, %Req.TransportError{reason: reason}} when is_atom(reason) ->
        # A transport failure names the network condition the guest needs
        # (:econnrefused, :nxdomain) — an atom, never an internal term.
        duration_ms = System.monotonic_time(:millisecond) - start_time
        emit_telemetry(component_ref, request, :error, duration_ms)
        encode_error(:http_error, "HTTP request failed: #{reason}")

      {:error, exception} ->
        # The exception's own message can carry host internals; the guest
        # gets a generic sentence and the detail stays in the host log.
        duration_ms = System.monotonic_time(:millisecond) - start_time
        emit_telemetry(component_ref, request, :error, duration_ms)

        Logger.warning(
          "[Opus.HttpHandler] request for #{component_ref} failed: #{Exception.message(exception)}"
        )

        encode_error(:http_error, "HTTP request failed")
    end
  end

  # A redirecting answer is the guest's to follow: where it points is the
  # attempt's next hop from this request's pin.
  defp note_redirect(host, request, %Req.Response{status: status} = response)
       when status in [301, 302, 303, 307, 308] do
    case Req.Response.get_header(response, "location") do
      [location | _] -> Opus.Egress.redirected(host, request.pinned, request.url, location)
      [] -> :ok
    end
  end

  defp note_redirect(_host, _request, _response), do: :ok

  defp request_timeout(limits) do
    HttpRequestValidation.timeout_ms(limits, @request_timeout)
  end

  defp build_req_opts(request, limits) do
    # Preserve the pinned URL and transport options from Opus.Egress.pin/3,
    # including disabled automatic retries and response decoding.
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

  # Never inspect/1 toward the guest: Elixir term syntax in a body reads
  # as data to whatever parses it next.
  defp normalize_response_body(body) when is_map(body) or is_list(body),
    do: Prima.Json.safe_encode(body)

  defp normalize_response_body(body), do: to_string(body)

  # ============================================================================
  # Private: Response Encoding
  # ============================================================================

  defp safe_encode(data), do: Prima.WitResponse.safe_encode(data)

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
  def encode_error(type, message), do: Prima.WitResponse.encode_error(type, message)

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
