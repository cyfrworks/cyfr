# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Egress do
  @moduledoc """
  Bounded control-plane HTTP transport over `Sanctum.Network.pin/2`.

  Every request connects to the validated address with the original TLS
  hostname and Host identity. Redirects, retries and content decoding remain
  disabled; callers validate and pin any subsequent destination themselves.
  """

  import Cyfr.MapUtil, only: [put_unless_nil: 3]

  @doc """
  Issue an HTTP request with SSRF protection AND DNS-rebinding protection.

  Resolves and validates the host once (`Sanctum.Network.pin/2`), then connects
  to that validated IP while preserving the original hostname for SNI / cert
  verification / `Host` (no second DNS resolution → no rebinding window). The
  body is returned raw (no decompression/decoding) and redirects are NOT
  followed, so callers stay in control of redirect validation.

  Returns a Finch-style 4-tuple `{:ok, status, headers, body}` (headers as a
  `[{name, value}]` list) or `{:error, reason}`.

  ## Options

    * `:private_policy` — see `Sanctum.Network.pin/2` (default `:deny`)
    * `:resolver` — see `Sanctum.Network.pin/2` (default `:inet`)
    * `:receive_timeout` — ms (default 30_000)
    * `:protocols` — Mint protocols list (e.g. `[:http1]`)
    * `:transport_opts` — extra Mint transport opts
    * `:max_response_bytes` — enforce a response-size ceiling WHILE the
      body streams in (via `Cyfr.BoundedBody.collector/1`), aborting the transfer
      at the limit instead of buffering an arbitrarily large body first.
      Exceeding it returns `{:error, {:response_too_large, size, max}}`.
  """
  @spec pinned_request(atom(), String.t(), [{String.t(), String.t()}], binary() | nil, keyword()) ::
          {:ok, non_neg_integer(), [{String.t(), String.t()}], binary()} | {:error, term()}
  def pinned_request(method, url, headers \\ [], body \\ nil, opts \\ []) do
    # The identity semantics matter here: no accept-encoding and no decode
    # (OCI digest verification hashes the body as received), no redirects,
    # no Req-level retry — `pin/2` bakes exactly that policy in, and this
    # adds only the method, the headers, the body and the ceiling.
    case Sanctum.Network.pin(url, opts) do
      {:ok, %{req_opts: req_opts}} ->
        max_bytes = Keyword.get(opts, :max_response_bytes)

        req_opts =
          req_opts
          |> Keyword.put(:method, method)
          |> Keyword.put(:headers, headers)
          |> put_unless_nil(:body, body)
          |> put_unless_nil(:into, max_bytes && Cyfr.BoundedBody.collector(max_bytes))

        case Req.request(req_opts) do
          {:ok, %Req.Response{status: status, headers: resp_headers} = resp} ->
            with {:ok, resp_body} <- response_body(resp, max_bytes) do
              {:ok, status, flatten_headers(resp_headers), resp_body}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _type, message} ->
        {:error, message}
    end
  end

  defp response_body(%Req.Response{body: body}, nil), do: {:ok, body}
  defp response_body(resp, max_bytes), do: Cyfr.BoundedBody.read(resp, max_bytes)

  # Req returns headers as %{name => [values]}; flatten to the [{name, value}]
  # list shape the Finch-style callers expect.
  defp flatten_headers(headers) when is_map(headers) do
    Enum.flat_map(headers, fn {k, vs} ->
      Enum.map(List.wrap(vs), &{to_string(k), to_string(&1)})
    end)
  end
end
