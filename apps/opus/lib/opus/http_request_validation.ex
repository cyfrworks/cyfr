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
      pin → method atom

  Every check before the pin is the engine's own, made from the
  assignment's edge and limits (`Opus.EdgeGuard`). The pin is CYFR's: the
  address the URL may be reached at under the attempt's authority,
  including its private-address policy (`Opus.Egress.pin/3`). The engine
  resolves no name, and the runner connects nowhere: each handler sends
  the validated request through the runner's relay naming the pin, and
  the relay's service end (`Opus.Relay`) checks it again, takes it from
  the consented rate with a `take_rate` host call of its own, so CYFR
  counts it against the consented limit, and connects to the pinned
  address. A runner's own `take_rate` is refused there.
  A redirect's next hop to another origin than the pin it came from goes
  without any header that carries a credential
  (`Prima.Network.strip_credentials/1`).

  `validate/6` returns a validated request map (including the pinned
  address, the pin and the Req method atom) that each handler then
  sends through the relay its own way (buffered fetch vs. polling
  stream). Handlers own the relay's fetch, response handling, and
  telemetry; every pre-flight decision of the runner's lives here.

  ## A request naming a connection

  A request whose JSON names a `connection` (the need it is made on) is
  attached: CYFR makes it, with the credential that need is bound to
  attached, so the guest's request carries none of its own. It runs the
  same checks up to the request's size (the envelope bound, the parse,
  the method, scheme and domain against the edge, a multipart body
  encoded as it is sent, a base64 body decoded, the size), then is built
  as a `Prima.AttachedRequest` and read back as CYFR reads it, so the
  runner refuses exactly what CYFR refuses: a credential header
  (`credential_header_refused`), a header that routes, frames or
  overrides the request (`invalid_request`, naming it), or anything else
  that does not read. It asks for no pin and keeps its headers as the
  guest wrote them; the validated request carries `:attached`, the
  request to send, and no `:pinned`.
  """

  require Logger

  alias Opus.EdgeGuard
  alias Opus.HostClient
  alias Opus.HttpHandler
  alias Prima.AttachedRequest
  alias Prima.Authority.Blob.Edge
  alias Prima.Limits

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
          required(:method) => String.t(),
          required(:url) => String.t(),
          required(:hostname) => String.t(),
          required(:headers) => [{String.t(), String.t()}],
          required(:body) => binary(),
          required(:body_encoding) => String.t() | nil,
          required(:response_encoding) => String.t() | nil,
          required(:multipart) => list() | nil,
          required(:connection) => String.t() | nil,
          optional(:method_atom) => atom(),
          optional(:ip) => String.t(),
          optional(:pinned) => Opus.Egress.pinned(),
          optional(:attached) => AttachedRequest.t()
        }

  @doc """
  Parse and validate a guest HTTP request against the consent edge and node
  limits, and pin its URL through CYFR (`Opus.Egress.pin/3`) with `host`.

  Returns `{:ok, validated_request}` with `:ip` (the pinned address),
  `:pinned` (the pin) and `:method_atom` (the Req method) added, and the guest's
  credentials dropped from a cross-origin redirect hop's headers, or, for
  a request naming a connection, with `:attached` added and no pin;
  `{:error, type, message}` for a refusal the caller records; or
  `{:refused, type, message}` for a refusal of CYFR's, which CYFR has
  already recorded.

  ## Options

    * `:allow_multipart` — `false` rejects requests carrying a `multipart`
      field (the streaming transport cannot send one). Defaults to `true`.
    * `:purpose` — what the pin is asked for, or the attached request is
      made for: `:fetch` (default) or `:stream`.
  """
  @spec validate(String.t(), Edge.t() | nil, Limits.t(), HostClient.t(), String.t(), keyword()) ::
          {:ok, validated_request()}
          | {:error, atom(), String.t()}
          | {:refused, atom(), String.t()}
  def validate(
        json_request,
        edge,
        %Limits{} = limits,
        %HostClient{} = host,
        _component_ref,
        opts \\ []
      ) do
    purpose = Keyword.get(opts, :purpose, :fetch)

    with :ok <- envelope_bound(limits, json_request),
         {:ok, request} <- parse_request(json_request),
         :ok <- validate_method(edge, request.method),
         :ok <- validate_scheme(edge, request.url),
         :ok <- validate_domain(edge, request.url),
         :ok <- check_multipart_allowed(request, Keyword.get(opts, :allow_multipart, true)),
         {:ok, request} <- decode_request_body(request),
         :ok <- EdgeGuard.check_request_size(limits, request) do
      if request.connection, do: attached(request, purpose), else: pinned(request, host, purpose)
    end
  end

  defp pinned(request, host, purpose) do
    with {:ok, pinned} <- pin_url(host, request.url, purpose),
         {:ok, method_atom} <- validated_method_atom(request.method) do
      {:ok,
       request
       |> Map.put(:ip, pinned.ip)
       |> Map.put(:pinned, pinned)
       |> Map.put(:method_atom, method_atom)
       |> hop_headers(pinned)}
    end
  end

  # The request CYFR makes for a connection: built from the members the
  # guest wrote, its body as it is sent, written as the host call writes
  # it and read back as CYFR reads it, so the runner refuses what CYFR
  # would. No pin is asked: CYFR pins the request it makes.
  defp attached(request, purpose) do
    {headers, body} = HttpHandler.wire_body(request)

    built = %AttachedRequest{
      call_id: AttachedRequest.call_id(:crypto.strong_rand_bytes(16)),
      connection: request.connection,
      method: request.method,
      url: request.url,
      headers: headers,
      body: body,
      purpose: purpose
    }

    case built |> AttachedRequest.to_args() |> AttachedRequest.read() do
      {:ok, attached} ->
        {:ok, Map.put(request, :attached, attached)}

      {:error, :credential_header_refused} ->
        {:error, :credential_header_refused, Prima.Refusal.message(:credential_header_refused)}

      {:error, {:invalid_request, header}} ->
        {:error, :invalid_request, "An attached request cannot set the #{header} header."}

      {:error, _unread} ->
        {:error, :invalid_request, "The attached request does not read."}
    end
  end

  # Pin through CYFR: the relay's service end keeps the pin for the
  # attempt and connects to its address.
  defp pin_url(host, url, purpose) do
    case Opus.Egress.pin(host, url, purpose: purpose) do
      {:ok, pinned} -> {:ok, pinned}
      {:error, :invalid_url, message} -> {:error, :invalid_request, message}
      refusal -> refusal
    end
  end

  # A redirect's next hop to another origin carries none of the guest's
  # credentials: they were meant for the origin that redirected.
  defp hop_headers(request, pinned) do
    if Opus.Egress.cross_origin?(pinned),
      do: %{request | headers: Prima.Network.strip_credentials(request.headers)},
      else: request
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

  # Before `Jason.decode/1` sees the string, not after: the decoded-payload
  # ceiling cannot bound what it costs to produce the decoded payload.
  defp envelope_bound(limits, json_request) do
    case EdgeGuard.check_envelope_size(limits, json_request) do
      :ok ->
        :ok

      {:error, :request_too_large} ->
        {:error, :request_too_large,
         "Request exceeds the consented max_request_size for this component."}
    end
  end

  defp parse_request(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"method" => method, "url" => url} = req} ->
        uri = URI.parse(url)
        hostname = uri.host

        multipart = parse_multipart(req["multipart"])
        body = req["body"] || ""

        cond do
          is_nil(hostname) or hostname == "" ->
            {:error, :invalid_request, "Invalid URL: missing hostname"}

          # Body and multipart are mutually exclusive
          multipart != nil and body != "" ->
            {:error, :invalid_request, "Request cannot have both 'body' and 'multipart'"}

          true ->
            with {:ok, headers} <- parse_headers(req["headers"]),
                 {:ok, connection} <- parse_connection(req) do
              {:ok,
               %{
                 method: String.upcase(method),
                 url: url,
                 hostname: hostname,
                 headers: headers,
                 body: body,
                 body_encoding: req["body_encoding"],
                 response_encoding: req["response_encoding"],
                 multipart: multipart,
                 connection: connection
               }}
            end
        end

      {:ok, _} ->
        {:error, :invalid_request, "Invalid request: must include 'method' and 'url'"}

      {:error, _} ->
        {:error, :invalid_json, "Invalid JSON request"}
    end
  end

  # The need a request is made on, when it names one: a string, whose
  # grammar `Prima.AttachedRequest` holds it to.
  defp parse_connection(%{"connection" => connection}) when is_binary(connection),
    do: {:ok, connection}

  defp parse_connection(%{"connection" => _other}),
    do: {:error, :invalid_request, "Invalid connection: the name of a need, as a string"}

  defp parse_connection(_request), do: {:ok, nil}

  # Headers are an object of names to values or an array of `[name, value]`
  # pairs, each read into a `{name, value}` pair, the one shape every later
  # check — the request size, the credential strip of a cross-origin hop —
  # reads. An array holding anything else, or a value that is not a
  # scalar, is refused rather than passed on unread.
  defp parse_headers(nil), do: {:ok, []}

  defp parse_headers(headers) when is_map(headers),
    do: headers |> Enum.map(fn {name, value} -> [name, value] end) |> parse_header_pairs()

  defp parse_headers(headers) when is_list(headers), do: parse_header_pairs(headers)
  defp parse_headers(_), do: {:ok, []}

  defp parse_header_pairs(pairs) do
    Enum.reduce_while(pairs, {:ok, []}, fn
      [name, value], {:ok, acc} when is_binary(name) and name != "" ->
        case header_value(value) do
          {:ok, value} -> {:cont, {:ok, [{name, value} | acc]}}
          :error -> {:halt, invalid_headers()}
        end

      _other, _acc ->
        {:halt, invalid_headers()}
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      refused -> refused
    end
  end

  defp header_value(value) when is_binary(value), do: {:ok, value}

  defp header_value(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: {:ok, to_string(value)}

  defp header_value(_value), do: :error

  defp invalid_headers,
    do:
      {:error, :invalid_request,
       "Invalid headers: an object of names to values, or an array of [name, value] pairs"}

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

  # After the edge checks and the pin, map supported HTTP method strings to Req atoms.
  defp validated_method_atom(method) do
    case Map.fetch(@valid_http_methods, method) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :method_blocked, "Unsupported HTTP method: #{method}"}
    end
  end
end
