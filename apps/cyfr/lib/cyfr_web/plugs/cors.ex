# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.CORS do
  @moduledoc """
  Minimal CORS plug for the Emissary MCP endpoint.

  Handles OPTIONS preflight requests and sets CORS headers on all responses.
  Allowed origins are configurable — wildcard by default, or a restricted
  list when an explicit allowlist is configured.

  ## Why the header list is derived

  MCP 2026-07-28 mirrors body fields into `Mcp-Method`, `Mcp-Name` and
  `MCP-Protocol-Version`, and `Emissary.Web.Plugs.MCPRequestMetadata` rejects a request
  that omits any of them. A preflight that does not advertise a required header
  is a failure the browser raises *before* the request is sent, so no server-side
  error can explain it — and the failure is invisible to the bundled deployment,
  where the PWA is proxied same-origin and never preflights at all.

  Both sides therefore read `Prima.MCP.Protocol.request_headers/0`, and
  `CyfrWeb.Plugs.CORSTest` asserts they agree.

  ## Any origin

  A mount that sets `any_origin: true` answers every origin `*`, whatever
  the deployment's list, and never allows credentials: a route whose only
  credential is in the request itself, with no session read, as a
  certified device's renewal at its person's home is (`/certify/v1/renew`,
  reached from the other home's page). A wildcard never carries cookies, so
  nothing ambient is ever sent or read on its behalf. The `null` origin is
  still answered only where `null_origin: true` says so.

  ## Configuration

      # Default — no cross-origin browser caller
      config :cyfr, :cors_allowed_origins, []

      # Allow all origins (refused at boot once authentication is configured)
      config :cyfr, :cors_allowed_origins, ["*"]

      # Restrict to known origins
      config :cyfr, :cors_allowed_origins, ["https://app.cyfr.run"]

  Note that `access-control-allow-credentials` is only sent for a named origin:
  the wildcard and credentials are mutually exclusive per the Fetch standard, so
  a deployment that needs cookie-bearing cross-origin calls must name its
  origins.

  ## The null origin

  A tincture's frame is a sandboxed document without `allow-same-origin`,
  so every request it makes carries `Origin: null`. Only a mount that sets
  `null_origin: true` — the tincture data routes, which authenticate the
  frame's bearer and nothing else — answers that origin, echoing `null`
  and never allowing credentials, so no cookie is ever sent on its behalf.
  Everywhere else a `null` origin is answered as a disallowed one, the
  wildcard included: an opaque origin is any sandboxed document at all,
  and a route that keeps the deployment's list and its session never
  serves one.
  """

  import Plug.Conn

  @behaviour Plug

  # Derived from `Prima.MCP.Protocol` rather than written out, because the
  # plug that *requires* these headers reads the same list. A preflight that
  # omits a required header rejects the request in the browser, before any of
  # this server's own error handling can explain why.
  @base_headers ~w(content-type authorization accept)

  @default_headers @base_headers
                   |> Enum.concat(Prima.MCP.Protocol.request_headers())
                   |> Enum.uniq()

  @expose_headers Prima.MCP.Protocol.exposed_headers() |> Enum.join(", ")

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
    * `:null_origin` — answer the `null` origin (default `false`); see
      "The null origin" above.
    * `:any_origin` — answer every other origin `*`, never with
      credentials (default `false`); see "Any origin" above.

  Mounts share this plug but route different verbs and accept different
  headers — `/mcp` is POST-only in this protocol revision, while
  `/api/executions/:id/events` is a GET — so neither list can be a module
  constant.
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
    |> Keyword.put(:null_origin, Keyword.get(opts, :null_origin, false) == true)
    |> Keyword.put(:any_origin, Keyword.get(opts, :any_origin, false) == true)
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

  # The bare-opts fallback, derived ONCE at compile time — this ran
  # init([])'s list-pipeline on every request, including preflights.
  @default_allowed_methods @default_methods
                           |> Enum.map(&String.upcase/1)
                           |> Enum.concat(["OPTIONS"])
                           |> Enum.uniq()
                           |> Enum.join(", ")
  @default_allowed_headers Enum.join(Enum.uniq(@default_headers), ", ")

  defp put_cors_headers(conn, opts) do
    allowed_methods = Keyword.get(opts, :allowed_methods) || @default_allowed_methods
    allowed_headers = Keyword.get(opts, :allowed_headers) || @default_allowed_headers
    origin = get_req_header(conn, "origin") |> List.first()
    allowed = allowed_origins()

    allow_origin =
      cond do
        origin == "null" -> if Keyword.get(opts, :null_origin, false), do: "null"
        Keyword.get(opts, :any_origin, false) -> "*"
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

      # Neither the wildcard nor an opaque origin is ever told credentials
      # may travel: the one a null origin presents is its bearer.
      if allow_origin not in ["*", "null"] do
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
