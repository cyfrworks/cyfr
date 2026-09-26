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
      egress rate limit → pin → method atom

  Every check before the pin is the engine's own, made from the
  assignment's edge and limits (`Opus.EdgeGuard`). The egress rate is taken
  through the attempt's host client (`Opus.HostClient.take_rate/2`), so
  CYFR counts it against the consented limit. The pin is CYFR's: the
  address the URL may be reached at under the attempt's authority,
  including its private-address policy, obtained and turned into a pinned
  connection by `Opus.Egress.pin/3`. The engine resolves no name, and
  duplicates neither the address classes nor the pinned transport policy.
  A redirect's next hop to another origin than the pin it came from goes
  without the guest's `Authorization` and `Cookie` headers.

  `validate/6` returns a validated request map (including the pinned
  address, the pin and the Req method atom) that each handler then
  executes its own way (buffered fetch vs. polling stream). Handlers own
  transport, response handling, and telemetry; every pre-flight decision
  lives here.
  """

  require Logger

  alias Opus.EdgeGuard
  alias Opus.HostClient
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
          pin_req_opts: keyword(),
          pinned: Opus.Egress.pinned()
        }

  @doc """
  Parse and validate a guest HTTP request against the consent edge and node
  limits, take it from the consented rate through `host`, and pin its URL
  through CYFR (`Opus.Egress.pin/3`).

  Returns `{:ok, validated_request}` with `:ip` (the pinned address),
  `:pin_req_opts` (the pinned connection's Req options), `:pinned` (the
  pin) and `:method_atom` (the Req method) added, and the guest's
  credentials dropped from a cross-origin redirect hop's headers;
  `{:error, type, message}` for a refusal the caller records; or
  `{:refused, type, message}` for a refusal of CYFR's, which CYFR has
  already recorded.

  ## Options

    * `:allow_multipart` — `false` rejects requests carrying a `multipart`
      field (the streaming transport cannot send one). Defaults to `true`.
    * `:purpose` — what the pin is asked for: `:fetch` (default) or
      `:stream`.
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
        component_ref,
        opts \\ []
      ) do
    with :ok <- envelope_bound(limits, json_request),
         {:ok, request} <- parse_request(json_request),
         :ok <- validate_method(edge, request.method),
         :ok <- validate_scheme(edge, request.url),
         :ok <- validate_domain(edge, request.url),
         :ok <- check_multipart_allowed(request, Keyword.get(opts, :allow_multipart, true)),
         {:ok, request} <- decode_request_body(request),
         :ok <- EdgeGuard.check_request_size(limits, request),
         :ok <- check_egress_rate(host, component_ref),
         {:ok, pinned} <- pin_url(host, request.url, Keyword.get(opts, :purpose, :fetch)),
         {:ok, method_atom} <- validated_method_atom(request.method) do
      {:ok,
       request
       |> Map.put(:ip, pinned.ip)
       |> Map.put(:pin_req_opts, pinned.req_opts)
       |> Map.put(:pinned, pinned)
       |> Map.put(:method_atom, method_atom)
       |> hop_headers(pinned)}
    end
  end

  # Pin through CYFR with the pinned transport's Req options, including
  # explicit retry and decode behavior.
  defp pin_url(host, url, purpose) do
    case Opus.Egress.pin(host, url, purpose: purpose, protocols: [:http1]) do
      {:ok, pinned} -> {:ok, pinned}
      {:error, :invalid_url, message} -> {:error, :invalid_request, message}
      refusal -> refusal
    end
  end

  # A redirect's next hop to another origin carries none of the guest's
  # credentials: they were meant for the origin that redirected.
  defp hop_headers(request, pinned) do
    if Opus.Egress.cross_origin?(pinned),
      do: %{request | headers: Opus.Egress.strip_credentials(request.headers)},
      else: request
  end

  # The consented rate limit, on the wire-bound path itself: the WIT
  # contract promises the host enforces rate limits before executing the
  # request. Keyed per component under the node's `http:` bucket, counted
  # by CYFR through a `take_rate` host call; before the pin, so a denied
  # caller cannot have an address pinned either. A host call CYFR refuses
  # fails CLOSED.
  defp check_egress_rate(host, component_ref) do
    case HostClient.take_rate(host, "http:" <> component_ref) do
      :ok ->
        :ok

      {:error, {:guest_error, _type, message}} ->
        {:error, :rate_limited, message}

      {:error, :unavailable} ->
        {:error, :rate_limited, "HTTP egress refused: rate limiter unavailable"}

      {:error, {:uncertain, sentence}} ->
        {:error, :rate_limited, "HTTP egress refused: " <> sentence}

      {:error, _refusal} ->
        {:error, :rate_limited, "HTTP egress refused: the execution attempt is not current"}
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

  # After the edge checks and the pin, map supported HTTP method strings to Req atoms.
  defp validated_method_atom(method) do
    case Map.fetch(@valid_http_methods, method) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :method_blocked, "Unsupported HTTP method: #{method}"}
    end
  end
end
