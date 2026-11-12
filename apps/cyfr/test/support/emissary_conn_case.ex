# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.ConnCase do
  @moduledoc """
  The test case for the MCP adapter: `CyfrWeb.ConnCase` with the
  helpers that speak to `/mcp` as a client does, the body sent as JSON
  bytes so the endpoint reads and parses it under its caps.

      use Emissary.Web.ConnCase, async: false

  The case's `conn` comes from a loopback address of its own test
  (`client_address/0`), as each person's client comes from its own: the
  transport's rate limit (`CyfrWeb.Plugs.MCPRateLimit`) counts per address,
  so a test is held to the shipped ceiling and no other test's requests
  count against it. A `conn` built afresh (`build_conn/0`) comes from
  `127.0.0.1`, which every such test shares.
  """

  defmacro __using__(opts) do
    quote do
      use CyfrWeb.ConnCase, unquote(opts)
      import Emissary.Web.ConnCase

      setup %{conn: conn} do
        {:ok, conn: %{conn | remote_ip: Emissary.Web.ConnCase.client_address()}}
      end
    end
  end

  @doc """
  A loopback address no other test of the run is given: `127.1.0.0` and up,
  clear of `127.0.0.0/16`, where the suite's fixed addresses live.
  """
  @spec client_address() :: :inet.ip4_address()
  def client_address do
    n = System.unique_integer([:positive, :monotonic])
    {127, 1 + rem(div(n, 65_536), 254), rem(div(n, 256), 256), rem(n, 256)}
  end

  @doc """
  POST a JSON-RPC message to `/mcp` as a conforming client, with `meta`
  merged into the `params._meta` it declares.

  Every request must declare its protocol version twice — in the
  `MCP-Protocol-Version` header and in `params._meta` — and the two must agree.
  Encoding that in one helper keeps the rule in a single place: a test asserts
  what it is about, and the next protocol revision is one edit here rather than
  eighty across the suite.

  Tests that deliberately send a malformed or non-conforming request call
  `mcp_post_as_is/2` instead.
  """
  def mcp_post(conn, body, meta \\ %{}) when is_map(body) and is_map(meta) do
    conn
    |> Plug.Conn.put_req_header("mcp-protocol-version", Prima.MCP.Protocol.version())
    |> put_mcp_routing_headers(body)
    |> mcp_post_as_is(conform_mcp_body(body, meta))
  end

  @doc """
  POST `body` to `/mcp` as it stands: a term encoded as JSON, or bytes
  sent as given, as `application/json` with their `content-length`, so the
  pipeline's parser reads them under the reader's cap
  (`CyfrWeb.Plugs.RawBodyReader`). Headers set on `conn` stay; nothing is
  added to the body.
  """
  def mcp_post_as_is(conn, body) when is_binary(body) do
    conn
    |> put_header_unless_set("content-type", "application/json")
    |> Plug.Conn.put_req_header("content-length", Integer.to_string(byte_size(body)))
    |> Phoenix.ConnTest.dispatch(CyfrWeb.Endpoint, :post, "/mcp", body)
  end

  def mcp_post_as_is(conn, body), do: mcp_post_as_is(conn, Jason.encode!(body))

  defp put_header_unless_set(conn, header, value) do
    case Plug.Conn.get_req_header(conn, header) do
      [] -> Plug.Conn.put_req_header(conn, header, value)
      _set -> conn
    end
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

  defp conform_mcp_body(%{"method" => _} = body, extra) do
    params = Map.get(body, "params") || %{}

    meta = %{
      Prima.MCP.Protocol.meta_protocol_version_key() => Prima.MCP.Protocol.version(),
      Prima.MCP.Protocol.meta_client_info_key() => %{"name" => "test", "version" => "0.0.0"},
      Prima.MCP.Protocol.meta_client_capabilities_key() => %{}
    }

    Map.put(body, "params", Map.put(params, "_meta", Map.merge(meta, extra)))
  end

  defp conform_mcp_body(body, _extra), do: body
end
