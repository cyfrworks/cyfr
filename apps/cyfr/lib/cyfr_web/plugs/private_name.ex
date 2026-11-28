# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.PrivateName do
  @moduledoc """
  A page request that came in by the loopback listener under any host
  name but the server's private name is sent to the same path and query
  at the private address (`Sanctum.private_address/0`): a page opened at
  `http://localhost:<port>` or `http://127.0.0.1:<port>` connects no
  socket there (`CyfrWeb.Ingress`), and at the private address it does.

  The destination is the configured address, which the tunnel key's
  public half names, never one the request gives: the host name only
  chooses between serving the page and sending it there, and decides no
  authority. A request at the proxy listener, and one that is not a GET
  or a HEAD, is served as it came. It runs in the browser pipelines alone
  (`CyfrWeb.Pipelines`), so the routes a program calls (the API, MCP,
  health, files, sockets) and the OAuth return, which completes under
  `http://localhost:<port>`, are never sent anywhere.
  """

  @behaviour Plug

  import Plug.Conn, only: [halt: 1, put_resp_header: 3, send_resp: 3]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: method} = conn, _opts) when method in ["GET", "HEAD"] do
    private = Sanctum.private_address()

    if Sanctum.ClientIp.ingress(conn) == :loopback and
         String.downcase(conn.host) != URI.parse(private).host do
      conn
      |> put_resp_header("location", private <> conn.request_path <> query(conn))
      |> send_resp(302, "")
      |> halt()
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  defp query(%Plug.Conn{query_string: ""}), do: ""
  defp query(%Plug.Conn{query_string: query}), do: "?" <> query
end
