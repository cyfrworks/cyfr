# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.BrowserCSP do
  @moduledoc """
  Sets the Prism pages' same-origin content security policy for scripts,
  styles, images, fonts, LiveView and tincture iframes. Allows inline styles
  and data-URL images. Install after `put_secure_browser_headers` to replace
  its default CSP.
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
    |> EmissaryWeb.Plugs.ApiSecurityHeaders.maybe_hsts()
  end
end
