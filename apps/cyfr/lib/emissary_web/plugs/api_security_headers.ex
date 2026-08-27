# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.ApiSecurityHeaders do
  @moduledoc """
  The closed header set for responses no browser should render: the API,
  the MCP transport, webhooks, health. Nothing may be loaded, nothing may
  frame it; HSTS rides along over TLS.
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
    |> maybe_hsts()
  end

  @doc """
  HSTS over TLS, skipped on plain HTTP. The one spelling of the policy —
  `BrowserCSP` applies the same header from here.
  """
  def maybe_hsts(%Plug.Conn{scheme: :https} = conn) do
    put_resp_header(conn, "strict-transport-security", "max-age=63072000; includeSubDomains")
  end

  def maybe_hsts(conn), do: conn
end
