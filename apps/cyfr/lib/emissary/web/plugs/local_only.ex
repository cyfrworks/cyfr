# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.Plugs.LocalOnly do
  @moduledoc """
  A route for programs on this machine: it answers only a request the
  loopback listener accepted (`CyfrWeb.Ingress`) that names no `Origin`.
  Every other request is refused 403, a request no listener tagged among
  them. The listener's tag decides, never a forwarded address, so a header
  cannot lift the refusal, and any `Origin` is a browser's page, which a
  program has no reason to name.

  It marks every answer `cache-control: no-store`, the refusal included,
  so it runs before the rest of its pipeline.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    if Sanctum.ClientIp.ingress(conn) == :loopback and get_req_header(conn, "origin") == [],
      do: conn,
      else: CyfrWeb.ApiError.halt(conn, 403, :local_only, nil)
  end
end
