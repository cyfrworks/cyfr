# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.Headless do
  @moduledoc """
  A headless node serves the API, MCP and public tinctures and nothing a
  browser would open: with `CYFR_HEADLESS=true` (`config :cyfr, :headless`)
  every route on the `:browser` pipeline answers 404 — the sign-in pages,
  the web OAuth flow, `/a/<athanor>` and the rest of Prism. Codex still
  signs in through the `session` tool on `/mcp` (the device flow), and a
  catalyst's OAuth callback rides `:api`, so neither notices.

  Routes are compiled into the router; refusing them in the pipeline is
  the one place a runtime flag can act. First in the pipeline, so nothing
  else (a session, a claim gate) runs for a request that will not be served.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if Cyfr.RuntimeConfig.headless?() do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "This node is headless: no browser surface is served here.")
      |> halt()
    else
      conn
    end
  end
end
