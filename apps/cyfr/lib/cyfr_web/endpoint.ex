# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Endpoint do
  @moduledoc """
  The one endpoint. The API, the MCP transport, tinctures and the Prism
  LiveViews all answer here, at each of the server's addresses: the
  private address on this machine always, and the browser address when
  it has one.

  It serves on two listeners, the loopback listener whatever the browser
  address and the proxy listener with one, and each hands it a request
  tagged with the listener that accepted it before `call/2` below runs
  (`CyfrWeb.Ingress`): the tag, never a header, `Host` or `Origin`, is the
  boundary, and decides the request's address (`Sanctum.address/1`).

  Every answer starts refusing the camera, the microphone and screen
  capture (`call/2`): this is the one place that refusal lives, and
  Prism's own pages alone replace it (`CyfrWeb.Plugs.BrowserCSP`). The user
  has ruled that frames never get these devices, so no capability may
  open them. It cannot reach an answer to a failure in the endpoint's own
  plugs that is raised without its request (a static file's invalid
  path), which Phoenix renders from the request as it arrived, or an app
  Aqua put into its own browser, which is served there and not here.
  """

  use Boundary,
    top_level?: true,
    deps: [
      Arca,
      Sanctum,
      Cyfr,
      Compendium,
      Aqua,
      Opus,
      Emissary,
      Emissary.Web,
      Prism,
      PrismWeb,
      CyfrWeb,
      CyfrWeb.Router
    ],
    exports: [],
    check: [aliases: true]

  use Phoenix.Endpoint, otp_app: :cyfr

  require Prima.TestSeam

  # The session is stored in the cookie and signed: its contents can be
  # read but not tampered with. The salt is a domain separator, not a key
  # (signing strength comes from secret_key_base); a release always signs
  # under the one `config/runtime.exs` sets, and dev and test under this.
  @default_session_salt "CZdqUO1/"

  @doc """
  Session cookie options, for the session plug and the live socket's
  connect info. They emit `http_only: true`, `same_site: "Lax"`, and
  `secure:` tied to `:cookie_secure` (true in prod, false in dev/test).
  Thirty days: the browser session is the one credential a person's
  devices hold.
  """
  def session_options do
    [
      store: :cookie,
      key: "_cyfr_key",
      signing_salt: Application.get_env(:cyfr, :session_salt, @default_session_salt),
      same_site: "Lax",
      http_only: true,
      secure: Cyfr.RuntimeConfig.cookie_secure?(),
      max_age: 30 * 24 * 60 * 60
    ]
  end

  # `:peer_data` and `:x_headers` are what `Sanctum.ClientIp.from_connect_info/1`
  # needs: the peer, the forwarded header and the listener's ingress tag,
  # which `CyfrWeb.Ingress` sets as a header for this reason. This socket
  # is handled here, before the router, so it passes no rate-limit plug and
  # a LiveView that starts an anonymous flow (sign-in, registry appeal) has
  # to budget by IP itself. `:user_agent` is what a sign-in's session
  # records its browser and system from (`Sanctum.UserAgent`).
  @live_connect_info [
    :peer_data,
    :x_headers,
    :user_agent,
    session: {__MODULE__, :session_options, []}
  ]

  # `/live`'s messages are bounded by the largest a LiveView sends
  # legitimately: the Files editor's save of a file it opens inline
  # (`Arca.Files.max_inline_read/0`), submitted as a form, which LiveView
  # encodes with `URLSearchParams`, so a byte outside its unreserved set
  # takes three. The long-poll client posts up to 100 queued messages in
  # one body, so the margin is a host call's body
  # (`Prima.HostAPI.max_body_bytes/0`): the save's own envelope, under a
  # kilobyte, and whatever else rides in its batch. A WebSocket frame and a
  # long-poll POST are held to the same bound (`socket_transports/0`), which
  # sits under the 8,000,000 bytes Phoenix's long-poll transport reads at
  # most. The socket takes its first messages before anyone is signed in,
  # so the bound is the editor's worst case and no more, moving with the
  # inline-read limit.
  @live_max_message_bytes Arca.Files.max_inline_read() * 3 + Prima.HostAPI.max_body_bytes()

  # The socket refuses every connect once a graceful stop begins
  # (`CyfrWeb.LiveSocket.drain/0`), on either transport.
  socket "/live", CyfrWeb.LiveSocket,
    websocket: [connect_info: @live_connect_info, max_frame_size: @live_max_message_bytes],
    longpoll: [connect_info: @live_connect_info]

  # A paired glass's device channel: the device protocol over a raw
  # WebSocket at `/device/websocket`. It carries the caller's address and
  # its listener's tag (`Sanctum.ClientIp.from_connect_info/1`) and no
  # session, so a cookie the browser holds never chooses the person.
  # A frame is capped at twice the largest valid glass message (a maximal
  # intent, 65,840 bytes), and the idle timeout sits above the channel's
  # 60-second proof deadline, so before a proof the deadline decides first.
  socket "/device", Emissary.Web.DeviceChannel,
    websocket: [
      connect_info: [:peer_data, :x_headers],
      max_frame_size: 131_072,
      timeout: 90_000
    ],
    longpoll: false

  @devices_refused "camera=(), microphone=(), display-capture=()"

  # A socket transport takes its request from `socket_dispatch`, the
  # plug `use Phoenix.Endpoint` declares ahead of every plug here; the
  # request carries its listener's tag already, set by the listener's plug
  # before this function runs (`CyfrWeb.Ingress`). The long-poll transport
  # reads a POST's body itself, up to 8 MB and under no cap of these
  # parsers, from whoever holds a transport token, which it hands to
  # anyone who asks. So a request to a socket transport's path
  # is bounded before that dispatch: a POST declares its length, within
  # the transport's bound (`socket_transports/0`), and any other request
  # carries no body. Every other one is refused before any byte of its
  # body is read, 413 (411 for a POST whose length is undeclared), and its
  # HTTP/1 connection ends.
  #
  # The devices' refusal is set ahead of that bound and that dispatch, so
  # a socket's refusal carries it as a route's answer does.
  @impl Plug
  def call(conn, opts) do
    conn =
      conn
      |> untagged()
      |> put_resp_header("permissions-policy", @devices_refused)

    case socket_body(conn) do
      :ok -> super(conn, opts)
      {:refused, status, reason} -> refuse_socket_body(conn, status, reason)
    end
  end

  # Every request a release serves was tagged by the listener that
  # accepted it (`CyfrWeb.Ingress`), and one no listener tagged comes in at
  # no address. A test build's request that `Phoenix.ConnTest` hands the
  # endpoint straight, past every listener, came in by the loopback
  # listener unless the test tagged it itself (`Prima.TestSeam.value/2`):
  # a release never reads this.
  defp untagged(conn) do
    Prima.TestSeam.value(conn, fn ->
      if Sanctum.ClientIp.ingress(conn) == nil,
        do: Sanctum.ClientIp.put_ingress(conn, :loopback),
        else: conn
    end)
  end

  @doc """
  Each socket transport the endpoint mounts, with the routed path it is
  dispatched on and the most bytes a POST to it may declare
  (`CyfrWeb.Ingress.socket_transports/1`, the one reading of them).
  """
  @spec socket_transports() :: [{:websocket | :longpoll, [String.t()], pos_integer()}]
  def socket_transports, do: CyfrWeb.Ingress.socket_transports(__MODULE__)

  # First, so every answer carries it, a refusal raised while parsing
  # among them (`close_unread/2`).
  plug(:close_unread)

  # Serve at "/" the static files from "priv/static" directory.
  #
  # When code reloading is disabled (e.g., in production),
  # the `gzip` option is enabled to serve compressed
  # static files generated by running `phx.digest`.
  plug(Plug.Static,
    at: "/",
    from: :cyfr,
    gzip: not code_reloading?,
    only: CyfrWeb.static_paths()
  )

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  # A private tincture's asset credential travels in its path (`/_s/…`).
  # Redacted from `conn.request_path` before anything names the request by
  # it — the endpoint's telemetry span, Phoenix's request log line, a
  # refusal of the ownership plug — while routing still reads `path_info`.
  plug(CyfrWeb.Plugs.ScrubTinctureCredentials)
  # The host's own metrics export (`/metrics`), the one adapter behind the
  # endpoint that is neither Emissary's nor Prism's: every route the
  # composition router serves is one of theirs.
  plug(CyfrWeb.MetricsPlug)
  plug(Plug.RequestId)
  # A boot that lost the control plane serves nothing but health.
  plug(CyfrWeb.Plugs.ControlPlaneOwnership)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  # Plug.Parsers behind the wrapper that refuses a multipart body before
  # reading any of it (`CyfrWeb.Plugs.RawBodyReader.parser_options/1`);
  # every parser failure keeps Phoenix's rendering.
  #
  # The endpoint parses before any route's rate limit or credential check,
  # so no caller here is authenticated, and the reader holds every body it
  # parses to a host call's (`Prima.HostAPI.max_body_bytes/0`, 1 MiB) or
  # its route's tighter cap: a declared length over it is refused 413
  # unread, a body of unknown length cut at it.
  #
  # No route takes a multipart body (LiveView uploads travel over the
  # socket), and the multipart parser reads one without RawBodyReader, so
  # up to the endpoint's length whatever the route's own cap. Multipart is
  # therefore not parsed, and a multipart request is refused 415 before
  # any byte of its body is read: every body the parsers read passes
  # RawBodyReader, whose caps hold for webhooks, the directory, the
  # restore ingress and a renewal.
  #
  # `/mcp`'s body is not read here. Its pipeline (`Emissary.Router`)
  # parses it under the same options, answered in JSON-RPC, only after
  # the transport's rate limit and authentication, so a flood or an
  # anonymous caller costs no read and decode of 28 MB.
  plug(:parse_body)

  plug(Plug.Head)
  plug(:dynamic_session)
  # Security headers but the devices' refusal (`call/2`) are a pipeline
  # concern: the API/MCP/webhook pipelines carry the closed set
  # (`CyfrWeb.Plugs.ApiSecurityHeaders`), the browser pipeline the
  # LiveView-compatible one (`CyfrWeb.Plugs.BrowserCSP`), and tinctures
  # their own.
  plug(CyfrWeb.Router)

  @parsers CyfrWeb.Plugs.ParserErrors.init(CyfrWeb.Plugs.RawBodyReader.parser_options())

  # The methods whose body `Plug.Parsers` reads.
  @body_methods CyfrWeb.Plugs.ParserErrors.body_methods()

  defp parse_body(%Plug.Conn{path_info: ["mcp" | _]} = conn, _opts), do: conn
  defp parse_body(conn, _opts), do: CyfrWeb.Plugs.ParserErrors.call(conn, @parsers)

  # An answer sent while the request's body is unread ends an HTTP/1
  # connection, so the server does not read the rest of the caller's body
  # to keep it alive: one refused before it was parsed or past its cap, and
  # one no parser read (a media type passed unparsed, a method whose body is
  # not parsed). HTTP/2 forbids the header (RFC 9113 §8.2.2) and resets the
  # unread stream itself.
  defp close_unread(conn, _opts), do: register_before_send(conn, &close_if_unread/1)

  defp close_if_unread(conn) do
    if unread?(conn), do: close_http1(conn), else: conn
  end

  defp close_http1(conn) do
    if conn |> get_http_protocol() |> Atom.to_string() |> String.starts_with?("HTTP/1"),
      do: put_resp_header(conn, "connection", "close"),
      else: conn
  end

  defp socket_body(%Plug.Conn{path_info: path_info} = conn) do
    case Enum.find(socket_transports(), &(elem(&1, 1) == path_info)) do
      {_transport, _path_info, bound} -> socket_body_bounded(conn, bound)
      nil -> :ok
    end
  end

  defp socket_body_bounded(%Plug.Conn{method: "POST"} = conn, cap) do
    case get_req_header(conn, "content-length") do
      [declared] ->
        case Integer.parse(declared) do
          {bytes, ""} when bytes in 0..cap//1 -> :ok
          _over_or_unparseable -> {:refused, 413, :socket_body_too_large}
        end

      _undeclared_or_repeated ->
        {:refused, 411, :socket_body_length_required}
    end
  end

  defp socket_body_bounded(conn, _cap),
    do: if(carries_body?(conn), do: {:refused, 413, :socket_body_too_large}, else: :ok)

  defp refuse_socket_body(conn, status, reason) do
    conn
    |> close_http1()
    |> CyfrWeb.ApiError.halt(status, reason, nil)
  end

  defp unread?(conn) do
    not CyfrWeb.Plugs.RawBodyReader.read?(conn) and
      (unparsed_body_method?(conn) or carries_body?(conn))
  end

  defp unparsed_body_method?(%Plug.Conn{method: method, body_params: %Plug.Conn.Unfetched{}}),
    do: method in @body_methods

  defp unparsed_body_method?(_conn), do: false

  # HTTP/1 frames a body by its `content-length` or its `transfer-encoding`.
  defp carries_body?(conn) do
    case get_req_header(conn, "content-length") do
      [] -> get_req_header(conn, "transfer-encoding") != []
      [length] -> Integer.parse(length) != {0, ""}
      _many -> true
    end
  end

  defp dynamic_session(conn, _opts) do
    # Session config is boot-static; the first request pays Plug.Session.init/1
    # once and pins the result instead of re-deriving it per request.
    opts =
      case :persistent_term.get({__MODULE__, :session_plug_opts}, nil) do
        nil ->
          opts = Plug.Session.init(session_options())
          :persistent_term.put({__MODULE__, :session_plug_opts}, opts)
          opts

        opts ->
          opts
      end

    Plug.Session.call(conn, opts)
  end
end
