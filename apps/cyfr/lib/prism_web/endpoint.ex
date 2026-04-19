defmodule PrismWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :cyfr

  @default_session_salt "pDm4TZ1kZUl1op-4"

  def session_options do
    salt = Application.get_env(:cyfr, :prism_session_salt, @default_session_salt)

    [
      store: :cookie,
      key: "_prism_key",
      signing_salt: salt,
      same_site: "Lax",
      http_only: true,
      secure: Application.get_env(:cyfr, :cookie_secure, false),
      max_age: 30 * 24 * 60 * 60
    ]
  end

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: {__MODULE__, :session_options, []}]],
    longpoll: [connect_info: [session: {__MODULE__, :session_options, []}]]

  plug Plug.Static,
    at: "/",
    from: :cyfr,
    gzip: not code_reloading?,
    only: PrismWeb.static_paths(),
    cache_static_manifest: "priv/static/cache_manifest.json"

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug :dynamic_session
  plug :security_headers
  plug PrismWeb.Router

  defp dynamic_session(conn, _opts) do
    opts = Plug.Session.init(session_options())
    Plug.Session.call(conn, opts)
  end

  defp security_headers(conn, _opts) do
    headers = [
      {"x-content-type-options", "nosniff"},
      {"x-frame-options", "SAMEORIGIN"},
      {"referrer-policy", "strict-origin-when-cross-origin"},
      {"content-security-policy",
       "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: #{emissary_origin()}; font-src 'self'; connect-src 'self' wss: ws:; frame-src 'self' #{emissary_origin()}; frame-ancestors 'self'"}
    ]

    # Add HSTS only when serving over TLS (production)
    headers =
      if conn.scheme == :https do
        [{"strict-transport-security", "max-age=63072000; includeSubDomains"} | headers]
      else
        headers
      end

    Enum.reduce(headers, conn, fn {key, value}, conn ->
      Plug.Conn.put_resp_header(conn, key, value)
    end)
  end

  # Tincture iframes are served by EmissaryWeb — PrismWeb needs to allow framing them.
  defp emissary_origin do
    EmissaryWeb.Endpoint.url()
  rescue
    _ -> "http://127.0.0.1:4000"
  end
end
