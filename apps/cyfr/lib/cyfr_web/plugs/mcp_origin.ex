# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.MCPOrigin do
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
    `CyfrWeb.ApiError`. A JSON-RPC route passes its own renderer.

  ## Configuration

  An origin is allowed when it is the address of the listener that
  accepted the request (`Sanctum.address/1` of `Sanctum.ClientIp.ingress/1`):
  the private address on the loopback listener, the browser address on the
  proxy listener. Never `Host` or any other header: the entry decides.
  Beside it, `CYFR_MCP_ALLOWED_ORIGINS` names extras
  (`Cyfr.RuntimeConfig.mcp_extra_origins/0`), where a localhost origin
  without a port admits that origin on any port.
  """

  import Plug.Conn
  require Logger

  @default_errors CyfrWeb.ApiError

  def init(opts), do: Keyword.put_new(opts, :errors, @default_errors)

  def call(conn, opts) do
    errors = Keyword.fetch!(opts, :errors)

    case get_req_header(conn, "origin") do
      [origin | _] ->
        if valid_origin?(origin, Sanctum.address(Sanctum.ClientIp.ingress(conn))) do
          conn
        else
          Logger.warning("[MCP Origin] Rejected origin: #{origin}")

          errors.halt(conn, 403, :origin_rejected, "Origin not allowed: #{origin}")
        end

      [] ->
        conn
    end
  end

  defp valid_origin?(origin, own) do
    (is_binary(own) and origin == own) or
      Enum.any?(Cyfr.RuntimeConfig.mcp_extra_origins(), &origin_matches?(origin, &1))
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
