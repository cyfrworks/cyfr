# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.ParserErrors do
  @moduledoc """
  `Plug.Parsers`, with the MCP endpoint's failures answered in JSON-RPC.

  A malformed body used to raise `Plug.Parsers.ParseError` out of the
  endpoint and render Phoenix's `{"errors":{"detail":"Bad Request"}}` —
  no envelope, no `-32700`, and the request id lost, which is exactly the
  drift `EmissaryWeb.MCPError` exists to prevent (the id cannot be echoed
  here: it was inside the body that failed to parse, so `null` is the
  honest value). The same path also gates the content type: `pass:
  ["*/*"]` let a `text/plain` POST reach the controller with empty params
  and be misreported as "Missing jsonrpc field".

  Every other path keeps Phoenix's behaviour — the failure re-raises.
  """

  @behaviour Plug

  alias Emissary.MCP.Message

  @protocol_version_header "mcp-protocol-version"

  @impl true
  def init(opts), do: Plug.Parsers.init(opts)

  @impl true
  def call(conn, opts) do
    with :ok <- check_mcp_content_type(conn) do
      Plug.Parsers.call(conn, opts)
    else
      {:error, message} ->
        answer(conn, 400, :parse_error, message)
    end
  rescue
    e in Plug.Parsers.ParseError ->
      if mcp?(conn) do
        # Generic on purpose: the parser's own message can echo attacker
        # bytes from the body.
        answer(conn, 400, :parse_error, "The request body is not parseable JSON")
      else
        reraise e, __STACKTRACE__
      end

    e in Plug.Parsers.RequestTooLargeError ->
      if mcp?(conn) do
        answer(conn, 413, :invalid_request, "The request body exceeds the size limit")
      else
        reraise e, __STACKTRACE__
      end
  end

  defp check_mcp_content_type(%Plug.Conn{method: "POST"} = conn) do
    if mcp?(conn) do
      case Plug.Conn.get_req_header(conn, "content-type") do
        [type | _] ->
          case Plug.Conn.Utils.content_type(type) do
            {:ok, "application", "json", _params} -> :ok
            _ -> {:error, "Content-Type must be application/json"}
          end

        [] ->
          {:error, "Content-Type must be application/json"}
      end
    else
      :ok
    end
  end

  defp check_mcp_content_type(_conn), do: :ok

  defp mcp?(conn), do: String.starts_with?(conn.request_path, "/mcp")

  defp answer(conn, status, code, message) do
    body = Message.encode_error(nil, code, message)

    conn
    |> Plug.Conn.put_resp_header(@protocol_version_header, Emissary.MCP.Protocol.version())
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
    |> Plug.Conn.halt()
  end
end
