# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.ApiSecurityHeaders do
  @moduledoc """
  The closed header set for responses no browser should render: the API,
  the MCP transport, webhooks, health. Nothing may be loaded, nothing may
  frame it. HSTS is the proxy listener's, on every response it sends
  (`maybe_hsts/1`).
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
    |> put_resp_header("content-security-policy", "default-src 'none'; frame-ancestors 'none'")
  end

  # A loopback name, which never gets HSTS: a browser that pinned HTTPS for
  # it would hold every port of localhost, and by includeSubDomains every
  # `*.localhost` name, to it for two years. The Caddyfile's matcher spells
  # the same set.
  @loopback_host ~r/\A(localhost|.+\.localhost|127\.0\.0\.1|\[?::1\]?)\z/i

  @doc """
  The endpoint's HSTS, the one spelling of the policy, on the response
  `conn` sends when all three hold: the home's access settings give the endpoint
  HSTS (`:cyfr, :hsts` is `:endpoint_on_proxy`, a tailnet home's, which
  `config/runtime.exs` writes from `Cyfr.RuntimeConfig.resolve_access/1`),
  the proxy listener accepted the request (`Sanctum.ClientIp.ingress/1`),
  and its `Host` is not a loopback name: `localhost`, a name ending in
  `.localhost`, `127.0.0.1` or `::1`, in any case. Otherwise `conn` is
  answered as it is, so the loopback listener's responses never carry it.

  `CyfrWeb.Ingress` registers it on every response the proxy listener
  sends, success, error and refusal alike. A public home's HSTS is
  Caddy's, this value (`Caddyfile`), and `tests/proxy-hsts/run.sh` fails
  when its value differs from the one here; a local home has none.
  """
  @spec maybe_hsts(Plug.Conn.t()) :: Plug.Conn.t()
  def maybe_hsts(%Plug.Conn{} = conn) do
    if Application.fetch_env!(:cyfr, :hsts) == :endpoint_on_proxy and
         Sanctum.ClientIp.ingress(conn) == :proxy and
         not Regex.match?(@loopback_host, conn.host || "") do
      put_resp_header(conn, "strict-transport-security", "max-age=63072000; includeSubDomains")
    else
      conn
    end
  end
end
