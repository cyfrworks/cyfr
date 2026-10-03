# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.BrowserCSP do
  @moduledoc """
  Sets the Prism pages' same-origin content security policy for scripts,
  styles, images, fonts, LiveView and tincture iframes. Allows inline styles
  and data-URL images. A Prism page frames tinctures and is framed by
  nothing, itself included: `frame-ancestors 'none'` and
  `x-frame-options: DENY`. Install after `put_secure_browser_headers` to
  replace its default CSP.

  `connect: :https` widens `connect-src` to `'self' https:`, for the
  glass's page alone (`/pair`): a device certified by its person's own
  home renews its certificate there by `fetch`, and the page cannot know
  that home before it loads. Installed after the browser pipeline's own,
  it replaces that policy on the routes it is on, and nowhere else.
  """

  @behaviour Plug

  import Plug.Conn

  @directives [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data:",
    "font-src 'self'",
    :connect,
    "frame-src 'self'",
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "object-src 'none'"
  ]

  @connect %{self: "connect-src 'self'", https: "connect-src 'self' https:"}

  @csp Map.new(@connect, fn {name, connect} ->
         {name,
          Enum.map_join(@directives, "; ", fn
            :connect -> connect
            directive -> directive
          end)}
       end)

  @impl true
  def init(opts) do
    case Keyword.get(opts, :connect, :self) do
      connect when is_map_key(@connect, connect) -> connect
      _other -> raise ArgumentError, "connect: is :self or :https"
    end
  end

  @impl true
  def call(conn, connect) do
    conn
    |> put_resp_header("content-security-policy", Map.fetch!(@csp, connect))
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
    |> CyfrWeb.Plugs.ApiSecurityHeaders.maybe_hsts()
  end
end
