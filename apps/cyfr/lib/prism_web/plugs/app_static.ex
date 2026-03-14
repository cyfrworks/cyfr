defmodule PrismWeb.Plugs.AppStatic do
  @moduledoc """
  Plug that serves static files for iframe apps from the local app directory.

  Matches routes like `/apps/:publisher/:name/:version/*path` and serves
  files from the corresponding directory in `data/apps/`.

  Sets appropriate CSP headers for sandboxed iframe apps.
  """

  @behaviour Plug

  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["apps", publisher, name, version | rest]} = conn, _opts) do
    apps_dir = Application.get_env(:cyfr, :apps_dir, "data/apps")
    file_path = Path.join([apps_dir, publisher, name, version | rest])

    # Prevent directory traversal
    base = Path.expand(Path.join([apps_dir, publisher, name, version]))
    resolved = Path.expand(file_path)

    if String.starts_with?(resolved, base) && File.regular?(resolved) do
      conn
      |> put_csp_headers()
      |> put_content_type(resolved)
      |> Plug.Conn.send_file(200, resolved)
      |> Plug.Conn.halt()
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  # Also serve the SDK at /sdk/cyfr.js
  defp put_csp_headers(conn) do
    Plug.Conn.put_resp_header(
      conn,
      "content-security-policy",
      "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'none'; frame-ancestors 'self'"
    )
  end

  defp put_content_type(conn, path) do
    mime =
      case Path.extname(path) do
        ".html" -> "text/html"
        ".js" -> "application/javascript"
        ".css" -> "text/css"
        ".json" -> "application/json"
        ".svg" -> "image/svg+xml"
        ".png" -> "image/png"
        ".jpg" -> "image/jpeg"
        ".jpeg" -> "image/jpeg"
        ".gif" -> "image/gif"
        ".woff2" -> "font/woff2"
        ".woff" -> "font/woff"
        _ -> "application/octet-stream"
      end

    Plug.Conn.put_resp_content_type(conn, mime)
  end
end
