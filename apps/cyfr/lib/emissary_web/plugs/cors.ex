# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.CORS do
  @moduledoc """
  Minimal CORS plug for the Emissary MCP endpoint.

  Handles OPTIONS preflight requests and sets CORS headers on all responses.
  Allowed origins are configurable — wildcard by default, or a restricted
  list when an explicit allowlist is configured.

  ## Why the header list is derived

  MCP 2026-07-28 mirrors body fields into `Mcp-Method`, `Mcp-Name` and
  `MCP-Protocol-Version`, and `EmissaryWeb.Plugs.MCPRequestMetadata` rejects a request
  that omits any of them. A preflight that does not advertise a required header
  is a failure the browser raises *before* the request is sent, so no server-side
  error can explain it — and the failure is invisible to the bundled deployment,
  where the PWA is proxied same-origin and never preflights at all.

  Both sides therefore read `Emissary.MCP.Protocol.request_headers/0`, and
  `EmissaryWeb.Plugs.CORSTest` asserts they agree.

  ## Configuration

      # Default — allow all origins
      config :cyfr, :cors_allowed_origins, ["*"]

      # Restrict to known origins
      config :cyfr, :cors_allowed_origins, ["https://app.cyfr.run"]

  Note that `access-control-allow-credentials` is only sent for a named origin:
  the wildcard and credentials are mutually exclusive per the Fetch standard, so
  a deployment that needs cookie-bearing cross-origin calls must name its
  origins.
  """

  import Plug.Conn

  @behaviour Plug

  # Derived from `Emissary.MCP.Protocol` rather than written out, because the
  # plug that *requires* these headers reads the same list. A preflight that
  # omits a required header rejects the request in the browser, before any of
  # this server's own error handling can explain why.
  @base_headers ~w(content-type authorization accept)

  @default_headers @base_headers
                   |> Enum.concat(Emissary.MCP.Protocol.request_headers())
                   |> Enum.uniq()

  @expose_headers Emissary.MCP.Protocol.exposed_headers() |> Enum.join(", ")

  # Each mount declares the verbs it actually routes.
  @default_methods ~w(GET POST)

  @max_age "86400"

  @doc """
  Options:

    * `:methods` — request verbs this mount routes, upper-case, without
      `OPTIONS` (always appended). Defaults to `#{inspect(@default_methods)}`.
    * `:headers` — request headers this mount accepts *in addition* to the
      common set. `last-event-id` is the case that motivated it: it belongs to
      the execution event stream, not to MCP, and advertising it on the MCP
      endpoint claimed support for something no MCP handler reads.

  Mounts share this plug but route different verbs and accept different
  headers — `/mcp` is POST-only in this protocol revision, while `/t` also
  serves `GET /t/access-token` — so neither list can be a module constant.
  """
  @impl true
  def init(opts) do
    methods =
      opts
      |> Keyword.get(:methods, @default_methods)
      |> Enum.map(&String.upcase/1)
      |> Enum.concat(["OPTIONS"])
      |> Enum.uniq()
      |> Enum.join(", ")

    headers =
      @default_headers
      |> Enum.concat(Keyword.get(opts, :headers, []))
      |> Enum.uniq()
      |> Enum.join(", ")

    opts
    |> Keyword.put(:allowed_methods, methods)
    |> Keyword.put(:allowed_headers, headers)
  end

  @impl true
  def call(%Plug.Conn{method: "OPTIONS"} = conn, opts) do
    conn
    |> put_cors_headers(opts)
    |> send_resp(204, "")
    |> halt()
  end

  def call(conn, opts) do
    put_cors_headers(conn, opts)
  end

  defp put_cors_headers(conn, opts) do
    defaults = init([])
    allowed_methods = Keyword.get(opts, :allowed_methods) || defaults[:allowed_methods]
    allowed_headers = Keyword.get(opts, :allowed_headers) || defaults[:allowed_headers]
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
        |> put_resp_header("access-control-allow-methods", allowed_methods)
        |> put_resp_header("access-control-allow-headers", allowed_headers)
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

  defp allowed_origins, do: Cyfr.RuntimeConfig.cors_allowed_origins()
end
