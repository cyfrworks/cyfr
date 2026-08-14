# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.MCPError do
  @moduledoc """
  Sends a JSON-RPC error response from the MCP ingress plugs and controllers.

  Every rejection before the router — bad protocol version, disallowed origin,
  rate limit, auth failure — has to answer in JSON-RPC, and each site used to
  hand-roll the envelope. Thirteen copies drifted in one specific way: twelve of
  them hardcoded `"id" => nil`, so a client that sent `{"id": 7}` got back an
  error it could not correlate to its request. JSON-RPC requires the id be
  echoed.

  The id is recovered from the parsed body, which is available here because
  `Plug.Parsers` runs in the endpoint, ahead of the router pipeline. It is
  genuinely absent for a GET (no body) and for a batch, and `nil` is correct in
  those cases — which is the only case JSON-RPC allows it.
  """

  @behaviour EmissaryWeb.ErrorRenderer

  import Plug.Conn

  alias Emissary.MCP.Message

  @protocol_version Emissary.MCP.Protocol.version()
  @protocol_version_header Emissary.MCP.Protocol.protocol_version_header()

  @doc """
  Render a JSON-RPC error, echoing the request id when the body carried one.

  `code` is an atom from `Emissary.MCP.Message`'s tables or a numeric code.
  """
  @impl true
  def send(%Plug.Conn{} = conn, status, code, message) do
    conn
    # Declared here rather than at each call site. Every rejection from the MCP
    # endpoint has to carry it, and when each caller remembered separately one
    # of them eventually forgot.
    |> put_resp_header(@protocol_version_header, @protocol_version)
    |> challenge(status)
    |> put_status(status)
    |> Phoenix.Controller.json(Message.encode_error(request_id(conn), code, message))
  end

  # RFC 9110 §15.5.2: "The server generating a 401 response MUST send a
  # WWW-Authenticate header field containing at least one challenge applicable
  # to the target resource." A bare 401 leaves a client nothing to act on, and
  # every rejection here used to send one.
  #
  # The scheme is all this endpoint can honestly advertise: the credential is an
  # opaque bearer — a `cyfr_` API key or a Sanctum session token — not an OAuth
  # access token. A server that also implemented OAuth 2.1 would add
  # `resource_metadata=` here, pointing at its protected-resource document.
  defp challenge(conn, 401), do: Plug.Conn.put_resp_header(conn, "www-authenticate", "Bearer")
  defp challenge(conn, _status), do: conn

  @doc """
  Render a JSON-RPC error and halt the pipeline. The plug form of `send/4`.
  """
  @impl true
  def halt(%Plug.Conn{} = conn, status, code, message) do
    conn
    |> __MODULE__.send(status, code, message)
    |> Plug.Conn.halt()
  end

  @doc """
  The JSON-RPC `id` of the request being rejected, or `nil` when there is none.

  A batch (`%{"_json" => [...]}`) has no single id, and an unfetched or
  non-map body yields none either.
  """
  @spec request_id(Plug.Conn.t()) :: String.t() | integer() | nil
  def request_id(%Plug.Conn{body_params: %{"id" => id}}) when is_binary(id) or is_integer(id),
    do: id

  def request_id(_conn), do: nil
end
