# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.BrowserCSP do
  @moduledoc """
  The content-security policy of the Prism pages: everything from this
  origin and nothing else — scripts, styles (Tailwind's inline utilities
  need `'unsafe-inline'`), images (plus `data:` for the inline icons),
  fonts, the LiveView socket, and tincture iframes, which are same-origin
  now that one endpoint serves them. Placed after
  `put_secure_browser_headers`, whose own CSP it replaces.
  """

  @behaviour Plug

  import Plug.Conn

  @csp Enum.join(
         [
           "default-src 'self'",
           "script-src 'self'",
           "style-src 'self' 'unsafe-inline'",
           "img-src 'self' data:",
           "font-src 'self'",
           "connect-src 'self'",
           "frame-src 'self'",
           "frame-ancestors 'self'",
           "base-uri 'self'",
           "object-src 'none'"
         ],
         "; "
       )

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> put_resp_header("content-security-policy", @csp)
    |> put_resp_header("x-frame-options", "SAMEORIGIN")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
    |> maybe_hsts()
  end

  defp maybe_hsts(%Plug.Conn{scheme: :https} = conn) do
    put_resp_header(conn, "strict-transport-security", "max-age=63072000; includeSubDomains")
  end

  defp maybe_hsts(conn), do: conn
end
