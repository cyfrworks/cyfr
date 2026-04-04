defmodule PrismWeb.Plugs.PublicCors do
  @moduledoc """
  CORS for public tincture endpoints.

  Core mode: `Access-Control-Allow-Origin: *` (read-only query surface).
  Handles OPTIONS preflight requests with 204 + halt.
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
    case Application.get_env(:cyfr, :edition, :core) do
      :arx ->
        # Arx: reflect origin only if in allowlist
        origin = get_req_header(conn, "origin") |> List.first()

        if origin && arx_origin_allowed?(origin) do
          conn
          |> put_resp_header("access-control-allow-origin", origin)
          |> put_resp_header("vary", "Origin")
        else
          conn
        end

      _ ->
        # Core: allow all origins for read-only query surface
        # No Vary: Origin with wildcard — response doesn't vary by origin
        conn
        |> put_resp_header("access-control-allow-origin", "*")
    end
  end

  defp arx_origin_allowed?(_origin) do
    # Rejects all origins until org-aware allowlist is implemented (fail closed).
    # Tracked in Arx_Roadmap.md section 2.1h.
    false
  end
end
