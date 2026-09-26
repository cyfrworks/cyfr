# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HttpHandler do
  @moduledoc """
  Host function HTTP handler for WASM components.

  Provides the `cyfr:http/fetch` WASI host import. Validates the full
  request, including method, URL, headers, and body, before network I/O
  for both HTTP and HTTPS.

  ## Security Properties

  - **SSRF Prevention**: the engine resolves no name, and the runner has no
    network. CYFR pins the address each request connects to under the
    attempt's authority, applying its private-address policy
    (`Opus.HostClient.egress_pin/3`); the request goes through the runner's
    relay naming that pin, and the relay's service end (`Opus.Relay`)
    connects to exactly that address, with the original hostname kept for
    TLS SNI / certificate verification / the `Host` header, so there is no
    DNS-rebinding gap and no second resolution to rebind. A metadata
    address is refused even when CYFR answers one (`Opus.Egress`)
  - **Bounds outside the runner**: the relay checks the method, the scheme,
    the pinned host as a domain and the request's size again, takes the
    request from the consented rate, and stops the answer at the node's
    `max_response_size` and the attempt's deadline
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

  # How much longer than the node's timeout the handler waits for the
  # relay's next word, which the relay bounds by that timeout itself.
  @relay_grace_ms 5_000

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
  limits, pins its URL through CYFR and sends it through the runner's
  relay, which connects to that address and streams the answer back under
  the credit this handler grants as it reads. A redirecting answer (`3xx`
  with a `Location`) is answered to the guest as it is, and a request the
  guest then makes to where it points is the redirect's next hop
  (`Opus.Egress.redirected/4`).

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

    # The response ceiling is enforced WHILE the body streams in: this
    # handler grants the relay credit only up to the limit, and the relay
    # stops the answer there too, so a hostile server on an allowed domain
    # cannot make the runner buffer an arbitrarily large binary.
    max_bytes = limits.max_response_size

    result =
      with {:ok, relay, ref} <- relay_fetch(host, request) do
        collect(relay, ref, max_bytes, request_timeout(limits) + @relay_grace_ms)
      end

    duration_ms = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, status, headers, body} ->
        emit_telemetry(component_ref, request, status, duration_ms)
        note_redirect(host, request, status, headers)

        if request.response_encoding == "base64" do
          encode_response_base64(status, headers, body)
        else
          encode_response(status, headers, body)
        end

      {:error, :response_too_large, size} ->
        {:error, type, message} = EdgeGuard.check_response_bytes(limits, size)
        emit_telemetry(component_ref, request, :response_too_large, duration_ms)
        record_refusal(host, type, message)
        encode_error(type, message)

      {:error, :timeout} ->
        emit_telemetry(component_ref, request, :timeout, duration_ms)
        encode_error(:timeout, "HTTP request timed out after #{request_timeout(limits)}ms")

      {:error, code} ->
        {type, message} = fetch_error(code, limits)
        emit_telemetry(component_ref, request, :error, duration_ms)
        if refusal?(type), do: record_refusal(host, type, message)
        encode_error(type, message)
    end
  end

  @doc false
  # Send a validated request through the runner's relay, naming its pin:
  # its method, its path and query, its headers and its body, a multipart
  # body encoded here. Answers the relay and the fetch's ref, or a refusal
  # for a request the relay cannot carry. Shared with
  # `Opus.HttpStreamHandler`.
  @spec relay_fetch(HostClient.t(), map()) ::
          {:ok, GenServer.server(), non_neg_integer()} | {:error, atom()}
  def relay_fetch(%HostClient{relay: nil}, _request), do: {:error, :no_relay}

  def relay_fetch(%HostClient{relay: relay, attempt: attempt}, request) do
    uri = URI.parse(request.url)
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    path = if uri.query, do: path <> "?" <> uri.query, else: path
    {headers, body} = wire_body(request)

    case Opus.Relay.Runner.fetch(
           relay,
           attempt,
           request.pinned.target.id,
           request.method,
           path,
           headers,
           body
         ) do
      {:ok, ref} -> {:ok, relay, ref}
      {:error, _reason} -> {:error, :unsendable}
    end
  end

  @doc false
  # The guest error a fetch that ended early answers, by the relay's code.
  # Shared with `Opus.HttpStreamHandler`.
  @spec fetch_error(atom() | String.t(), Limits.t()) :: {atom(), String.t()}
  def fetch_error("timeout", limits),
    do: {:timeout, "HTTP request timed out after #{request_timeout(limits)}ms"}

  def fetch_error("rate_limited", _limits),
    do: {:rate_limited, "HTTP egress refused: the consented rate limit is exhausted"}

  def fetch_error("response_too_large", limits),
    do: {:response_too_large, "Response body exceeds limit (#{limits.max_response_size} bytes)"}

  def fetch_error("request_too_large", _limits),
    do: {:request_too_large, "Request exceeds the consented max_request_size for this component."}

  def fetch_error(code, _limits)
      when code in ["method_blocked", "scheme_blocked", "domain_blocked"],
      do: {String.to_existing_atom(code), "HTTP egress refused by the worker service's check"}

  def fetch_error("private_ip_blocked", _limits),
    do: {:private_ip_blocked, "metadata IP blocked"}

  def fetch_error(:no_relay, _limits),
    do: {:http_error, "HTTP request failed: the runner has no relay"}

  def fetch_error(:unsendable, _limits),
    do: {:invalid_request, "The request cannot be sent: its path or headers are malformed"}

  def fetch_error(code, _limits) when is_binary(code),
    do: {:http_error, "HTTP request failed: #{code}"}

  def fetch_error(_code, _limits), do: {:http_error, "HTTP request failed"}

  # A refusal of the worker service's checks is recorded for the audit
  # trail, as the runner's own are; a request that was made and failed is
  # not a refusal.
  defp refusal?(type),
    do:
      type in [
        :rate_limited,
        :request_too_large,
        :method_blocked,
        :scheme_blocked,
        :domain_blocked,
        :private_ip_blocked
      ]

  # The answer's status, headers and body, reading at most `max_bytes` of
  # it: each chunk read is granted back as credit, so the relay never holds
  # more than one window of it unread here.
  defp collect(relay, ref, max_bytes, timeout_ms) do
    receive do
      {Opus.Relay.Runner, ^ref, {:head, status, headers, body}} ->
        collect_body(
          relay,
          ref,
          max_bytes,
          timeout_ms,
          {status, headers},
          [body],
          byte_size(body)
        )

      {Opus.Relay.Runner, ^ref, {:end, error}} ->
        {:error, error || "http_error"}
    after
      timeout_ms ->
        Opus.Relay.Runner.cancel(relay, ref)
        {:error, :timeout}
    end
  end

  defp collect_body(relay, ref, max_bytes, _timeout_ms, _head, _acc, size)
       when size > max_bytes do
    Opus.Relay.Runner.cancel(relay, ref)
    {:error, :response_too_large, size}
  end

  defp collect_body(relay, ref, max_bytes, timeout_ms, {status, headers} = head, acc, size) do
    receive do
      {Opus.Relay.Runner, ^ref, {:chunk, body}} ->
        Opus.Relay.Runner.credit(relay, ref, byte_size(body))
        collect_body(relay, ref, max_bytes, timeout_ms, head, [acc, body], size + byte_size(body))

      {Opus.Relay.Runner, ^ref, {:end, nil}} ->
        {:ok, status, headers, IO.iodata_to_binary(acc)}

      {Opus.Relay.Runner, ^ref, {:end, "response_too_large"}} ->
        {:error, :response_too_large, max(size, max_bytes + 1)}

      {Opus.Relay.Runner, ^ref, {:end, error}} ->
        {:error, error}
    after
      timeout_ms ->
        Opus.Relay.Runner.cancel(relay, ref)
        {:error, :timeout}
    end
  end

  # The request's headers and body as the relay carries them: a multipart
  # request's parts encoded as `multipart/form-data` here, with the
  # boundary in its content type.
  defp wire_body(%{multipart: parts} = request) when is_list(parts) do
    boundary = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    body =
      IO.iodata_to_binary([
        Enum.map(parts, &multipart_part(&1, boundary)),
        "--",
        boundary,
        "--\r\n"
      ])

    headers =
      request.headers
      |> Enum.reject(fn {name, _value} -> String.downcase(name) == "content-type" end)
      |> Kernel.++([{"content-type", "multipart/form-data; boundary=#{boundary}"}])

    {headers, body}
  end

  defp wire_body(request), do: {request.headers, request.body}

  defp multipart_part(%{name: name, data: data} = part, boundary) do
    filename = if part.filename, do: ~s(; filename="#{quoted(part.filename)}"), else: ""

    [
      "--",
      boundary,
      "\r\n",
      ~s(content-disposition: form-data; name="#{quoted(name)}"#{filename}\r\n),
      "content-type: ",
      part.content_type || "application/octet-stream",
      "\r\n\r\n",
      data,
      "\r\n"
    ]
  end

  defp multipart_part(%{name: name, value: value}, boundary) do
    [
      "--",
      boundary,
      "\r\n",
      ~s(content-disposition: form-data; name="#{quoted(name)}"\r\n\r\n),
      value,
      "\r\n"
    ]
  end

  defp quoted(text), do: text |> to_string() |> String.replace(~s("), "%22")

  # A redirecting answer is the guest's to follow: where it points is the
  # attempt's next hop from this request's pin.
  defp note_redirect(host, request, status, headers)
       when status in [301, 302, 303, 307, 308] do
    case Enum.find(headers, fn {name, _value} -> String.downcase(name) == "location" end) do
      {_name, location} -> Opus.Egress.redirected(host, request.pinned, request.url, location)
      nil -> :ok
    end
  end

  defp note_redirect(_host, _request, _status, _headers), do: :ok

  defp request_timeout(limits) do
    HttpRequestValidation.timeout_ms(limits, @request_timeout)
  end

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
