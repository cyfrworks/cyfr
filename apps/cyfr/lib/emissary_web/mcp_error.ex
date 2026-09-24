# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.MCPError do
  @moduledoc """
  Sends a JSON-RPC error response from the MCP ingress plugs and controllers.

  Formats pre-router rejections as JSON-RPC errors and echoes a valid
  request id so clients can correlate failures.

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

  `code` is a numeric code, a code name from `Emissary.MCP.Message`'s
  tables, or a refusal — a `%Prima.Refusal{}` or a reason term — answered
  with its class's code (`Emissary.MCP.Message.refusal_code/2`).
  """
  @impl true
  def send(%Plug.Conn{} = conn, status, code, message) do
    {code, message} = wire(code, message)

    conn
    # Declared here rather than at each call site. Every rejection from the MCP
    # endpoint has to carry it, and when each caller remembered separately one
    # of them eventually forgot.
    |> put_resp_header(@protocol_version_header, @protocol_version)
    |> challenge(status)
    |> put_status(status)
    |> Phoenix.Controller.json(Message.encode_error(request_id(conn), code, message))
  end

  defp wire(code, message) when is_integer(code), do: {code, message}

  defp wire(code, message) do
    if Message.code?(code) do
      {code, message}
    else
      refusal = Grimoire.Error.classify(code)
      {Message.refusal_code(refusal, :transport), message || refusal.message}
    end
  end

  # HTTP 401 requires a WWW-Authenticate challenge (RFC 9110).
  # Advertise Bearer for API keys and Sanctum session tokens.
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
