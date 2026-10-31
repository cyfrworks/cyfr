# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.Plugs.SetupStatusFront do
  @moduledoc """
  What the setup status route (`Emissary.Web.SetupStatusController`)
  holds before anything else of the endpoint runs. The endpoint mounts it
  ahead of the ownership fence and the body parsers, because a pipeline
  runs after both: an ownership refusal and a body the parsers refuse
  would otherwise leave without `no-store`, and a malformed request
  uncounted.

  On `POST /api/setup/status` alone (`Prima.SetupStatus.path?/1`, the path
  as the router decodes it) it sets the closed header set, admits a local
  caller (`Emissary.Web.Plugs.LocalOnly`) and then counts the request
  against the local bucket, which a once-a-second poll stays under. A
  request off the loopback listener counts for nothing. Every other request
  passes untouched.

  The route's pipeline runs `LocalOnly` again, so the route stays closed to
  a remote caller by its own declaration, whatever this path match says.
  """

  use Plug.Builder

  plug CyfrWeb.Plugs.ApiSecurityHeaders
  plug Emissary.Web.Plugs.LocalOnly

  plug CyfrWeb.Plugs.AuthRateLimit,
    bucket: :setup_status,
    max_requests: 120,
    window_ms: 60_000

  @impl Plug
  def call(%Plug.Conn{method: "POST", path_info: path_info} = conn, opts) do
    if Prima.SetupStatus.path?(path_info), do: super(conn, opts), else: conn
  end

  def call(conn, _opts), do: conn
end
