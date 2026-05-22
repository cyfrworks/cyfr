# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.Plugs.PublicCors do
  @moduledoc """
  CORS for public tincture endpoints.

  Driven by `:cyfr, :cors_allowed_origins` (default `["*"]`). When it contains
  `"*"`, every origin is allowed (the fresh-install / no-auth default for the
  read-only query surface). Otherwise the request origin is reflected only when
  it is on the allowlist. Handles OPTIONS preflight with 204 + halt.

  The boot guard in `Cyfr.Application` raises on a wildcard once authentication
  is configured, so an auth-enabled deployment must supply an explicit list.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%{method: "OPTIONS"} = conn, _opts) do
    conn
    |> put_cors_headers()
    |> put_resp_header("access-control-allow-methods", "GET, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type")
    |> put_resp_header("access-control-max-age", "86400")
    |> send_resp(204, "")
    |> halt()
  end

  def call(conn, _opts) do
    conn
    |> put_cors_headers()
    |> put_resp_header("access-control-expose-headers", "retry-after")
  end

  defp put_cors_headers(conn) do
    origins = Application.get_env(:cyfr, :cors_allowed_origins, ["*"])

    if "*" in origins do
      # Wildcard. No Vary: Origin — the response doesn't vary by origin.
      put_resp_header(conn, "access-control-allow-origin", "*")
    else
      # Explicit allowlist: reflect the request origin only when it is listed.
      origin = get_req_header(conn, "origin") |> List.first()

      if origin && origin in origins do
        conn
        |> put_resp_header("access-control-allow-origin", origin)
        |> put_resp_header("vary", "Origin")
      else
        conn
      end
    end
  end
end
