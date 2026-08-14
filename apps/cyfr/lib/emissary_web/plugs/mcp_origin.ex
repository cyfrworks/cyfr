# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.MCPOrigin do
  @moduledoc """
  Origin validation, the defence against DNS rebinding: a page on any origin
  can make a browser issue requests to `localhost`, so a server bound there
  must check who is asking.

  "Servers MUST validate the `Origin` header on all incoming connections… If
  the `Origin` header is present and invalid, servers MUST respond with HTTP
  403 Forbidden." Absent is not invalid — a non-browser client sends none — so
  an absent header passes through.

  ## Options

  - `:errors` — the module that renders a rejection, defaulting to
    `EmissaryWeb.MCPError`. Use `EmissaryWeb.ApiError` on a route that does not
    speak JSON-RPC.

  ## Configuration

      config :cyfr, :mcp_allowed_origins, ["http://localhost", "https://localhost"]

  Supports wildcard port matching for localhost origins.
  """

  import Plug.Conn
  require Logger

  @default_errors EmissaryWeb.MCPError

  def init(opts), do: Keyword.put_new(opts, :errors, @default_errors)

  def call(conn, opts) do
    errors = Keyword.get(opts, :errors, @default_errors)

    case get_req_header(conn, "origin") do
      [origin | _] ->
        if valid_origin?(origin) do
          conn
        else
          Logger.warning("[MCP Origin] Rejected origin: #{origin}")

          errors.halt(
            conn,
            403,
            :insufficient_permissions,
            "Origin not allowed: #{origin}"
          )
        end

      [] ->
        conn
    end
  end

  defp valid_origin?(origin) do
    allowed = Cyfr.RuntimeConfig.mcp_allowed_origins()

    Enum.any?(allowed, fn allowed_origin ->
      origin_matches?(origin, allowed_origin)
    end)
  end

  # Exact match or localhost with any port
  defp origin_matches?(origin, allowed) do
    origin == allowed or
      (localhost_origin?(allowed) and localhost_with_port?(origin, allowed))
  end

  defp localhost_origin?(origin) do
    String.contains?(origin, "localhost") or
      String.contains?(origin, "127.0.0.1") or
      String.contains?(origin, "[::1]")
  end

  defp localhost_with_port?(origin, base) do
    # The suffix must be digits only — a prefix check alone would accept
    # `http://localhost:3000.evil.com`.
    case String.split(origin, base <> ":", parts: 2) do
      ["", port] -> port =~ ~r/^\d+$/
      _ -> false
    end
  end
end
