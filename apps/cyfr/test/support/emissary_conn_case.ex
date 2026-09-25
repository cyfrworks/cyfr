# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.ConnCase do
  @moduledoc """
  The test case for the MCP adapter: `CyfrWeb.ConnCase` with the
  helper that speaks to `/mcp` as a conforming client.

      use Emissary.Web.ConnCase, async: false
  """

  defmacro __using__(opts) do
    quote do
      use CyfrWeb.ConnCase, unquote(opts)
      import Emissary.Web.ConnCase
    end
  end

  @doc """
  POST a JSON-RPC message to `/mcp` as a conforming client.

  Every request must declare its protocol version twice — in the
  `MCP-Protocol-Version` header and in `params._meta` — and the two must agree.
  Encoding that in one helper keeps the rule in a single place: a test asserts
  what it is about, and the next protocol revision is one edit here rather than
  eighty across the suite.

  Tests that deliberately send a malformed or non-conforming request should call
  `post/3` directly instead.
  """
  def mcp_post(conn, body) when is_map(body) do
    conn
    |> Plug.Conn.put_req_header("mcp-protocol-version", Prima.MCP.Protocol.version())
    |> put_mcp_routing_headers(body)
    |> Phoenix.ConnTest.dispatch(CyfrWeb.Endpoint, :post, "/mcp", conform_mcp_body(body))
  end

  defp put_mcp_routing_headers(conn, body) do
    conn =
      case body["method"] do
        method when is_binary(method) -> Plug.Conn.put_req_header(conn, "mcp-method", method)
        _ -> conn
      end

    case Prima.MCP.Protocol.named_subject(body) do
      name when is_binary(name) -> Plug.Conn.put_req_header(conn, "mcp-name", name)
      _ -> conn
    end
  end

  defp conform_mcp_body(%{"method" => _} = body) do
    params = Map.get(body, "params") || %{}

    meta = %{
      Prima.MCP.Protocol.meta_protocol_version_key() => Prima.MCP.Protocol.version(),
      Prima.MCP.Protocol.meta_client_info_key() => %{"name" => "test", "version" => "0.0.0"},
      Prima.MCP.Protocol.meta_client_capabilities_key() => %{}
    }

    Map.put(body, "params", Map.put(params, "_meta", meta))
  end

  defp conform_mcp_body(body), do: body
end
