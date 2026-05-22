# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.CORS do
  @moduledoc """
  Minimal CORS plug for the Emissary MCP endpoint.

  Handles OPTIONS preflight requests and sets CORS headers on all responses.
  Allowed origins are configurable — wildcard by default, or a restricted
  list when an explicit allowlist is configured.

  ## Configuration

      # Default — allow all origins
      config :cyfr, :cors_allowed_origins, ["*"]

      # Restrict to known origins
      config :cyfr, :cors_allowed_origins, ["https://app.cyfr.run"]

  """

  import Plug.Conn

  @behaviour Plug

  @allowed_methods "GET, POST, DELETE, OPTIONS"
  @allowed_headers "content-type, authorization, mcp-session-id, last-event-id"
  @expose_headers "mcp-session-id"
  @max_age "86400"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts) do
    conn
    |> put_cors_headers()
    |> send_resp(204, "")
    |> halt()
  end

  def call(conn, _opts) do
    put_cors_headers(conn)
  end

  defp put_cors_headers(conn) do
    origin = get_req_header(conn, "origin") |> List.first()
    allowed = allowed_origins()

    allow_origin =
      cond do
        "*" in allowed -> "*"
        origin != nil and origin in allowed -> origin
        true -> nil
      end

    conn = put_resp_header(conn, "vary", "Origin")

    if allow_origin do
      conn =
        conn
        |> put_resp_header("access-control-allow-origin", allow_origin)
        |> put_resp_header("access-control-allow-methods", @allowed_methods)
        |> put_resp_header("access-control-allow-headers", @allowed_headers)
        |> put_resp_header("access-control-expose-headers", @expose_headers)
        |> put_resp_header("access-control-max-age", @max_age)

      if allow_origin != "*" do
        put_resp_header(conn, "access-control-allow-credentials", "true")
      else
        conn
      end
    else
      conn
    end
  end

  defp allowed_origins do
    Application.get_env(:cyfr, :cors_allowed_origins, ["*"])
  end
end