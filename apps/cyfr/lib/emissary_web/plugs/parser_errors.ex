# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.ParserErrors do
  @moduledoc """
  `Plug.Parsers`, with the MCP endpoint's failures answered in JSON-RPC.

  Returns JSON-RPC parse errors (-32700) for malformed MCP request bodies.
  The id is null because it cannot be read from an unparseable body.
  Rejects unsupported content types before controller dispatch.

  Every other path keeps Phoenix's behaviour — the failure re-raises.
  """

  @behaviour Plug

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

  # The one JSON-RPC rejection seam — the envelope, the protocol header
  # and the (absent, here correctly nil) request id all come from
  # `EmissaryWeb.MCPError`, not a fourteenth hand-rolled copy.
  defp answer(conn, status, code, message) do
    EmissaryWeb.MCPError.halt(conn, status, code, message)
  end
end
