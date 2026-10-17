# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.RawBodyReader do
  @moduledoc """
  Custom body reader for `Plug.Parsers` that preserves the raw request body
  *only* for the `/hooks/*` route family.

  Webhook signature verification (HMAC-SHA256) needs the exact bytes that the
  sender signed. Once `Plug.Parsers` has consumed the body, those bytes are
  gone — only `conn.body_params` remains. This reader buffers the raw bytes
  into `conn.assigns[:raw_body]` *before* parsing so the
  `CyfrWeb.Plugs.VerifyWebhookSignature` plug can recover them.

  To avoid memory pressure on hot paths (`/mcp`, `/t/*`, `/api/*`, etc.) the
  bytes are NOT cached unless the routed path (`conn.path_info`, which the
  router matches and which drops empty segments) begins with `hooks`.

  ## Per-feature length cap

  For `/hooks/*` paths we tighten the body length cap to a webhook-specific
  limit (default 1 MB, configurable via `:webhook_max_body_bytes`). Webhooks
  rarely need >100 KB; the tighter cap reduces memory churn from misbehaving
  senders. A sender is not authenticated before its body is read, so a host
  call's body bounds a larger configured cap (below).

  Bodies larger than the cap cause `Plug.Conn.read_body/2` to return
  `{:more, _, _}` — `Plug.Parsers` then raises `Plug.Parsers.RequestTooLargeError`,
  which Phoenix maps to a 413 response.

  ## The directory's write-body limit

  The identity directory's routes (a routed path beginning `directory`,
  `//directory/…` included) take requests no session
  stands behind, so their bodies are bounded to the largest entry
  (`Prima.Identity.max_entry_bytes/0`, 16 KiB) here, before any byte of
  them is decoded: a larger body is refused 413 the same way. Their raw
  bytes are not cached. The restore ingress (`/restore…`), which takes a
  printed kit before any person exists, is bounded the same way, and so
  is a certified device's renewal (`/certify…`), which a device sends
  holding no session.

  ## A caller no pipeline has authenticated

  Every request whose context is not authenticated — no credential, or
  one that established no one — is bounded to a host call's body
  (`Prima.HostAPI.max_body_bytes/0`, 1 MiB) the same way, on every path.
  Only `CyfrWeb.Plugs.Authenticate` establishes a context, and it runs in
  a route's pipeline, after the route's rate limit: the endpoint, which
  parses every body but `/mcp`'s before routing, never sees one, so no
  body it reads is longer. `/mcp`'s body is parsed in its own pipeline,
  after the transport's rate limit and `Authenticate` (`Emissary.Router`),
  and an authenticated caller there is granted the attachment allowance
  (28 MB), which carries the chat's base64 attachments.

  ## A declared length over the cap

  A request whose `content-length` is above the cap that applies to it is
  refused before any byte of its body is read: the reader answers
  `{:more, "", conn}`, which `Plug.Parsers` raises as
  `Plug.Parsers.RequestTooLargeError`. A body of unknown length is read
  only up to the cap, and no single read asks the adapter for more than
  it (`:read_length`).

  ## Every parsed body

  Every body the endpoint's parsers read passes through here, so these
  caps hold for each of them. The multipart parser would read without
  this reader, so the endpoint does not parse multipart: a multipart
  request is refused 415 before any of its body is read
  (`CyfrWeb.Plugs.ParserErrors`'s `:refuse`).

  ## A body read whole

  A body this reader has read to its end marks the connection
  (`read?/1`), so the endpoint can tell an answer sent with the body
  still unread, which ends its HTTP/1 connection.

  ## Chunked reads

  `Plug.Conn.read_body/2` returns `{:more, chunk, conn}` for partial reads
  (default `:read_length` is 1 MB). `Plug.Parsers` calls this body_reader
  iteratively and concatenates the chunks itself for parsing. This module
  *also* accumulates chunks into `conn.assigns[:raw_body]` so the cached
  copy matches the full body — required for HMAC verification of webhook
  payloads that exceed the per-chunk read length.
  """

  # The shared 1 MiB default (`Prima.Limits.default_max_request_size/0`),
  # spelled by its owner rather than a sixth literal.
  @default_webhook_max_body_bytes Prima.Limits.default_max_request_size()

  # The directory's write-body limit is its largest entry.
  @directory_max_body_bytes Prima.Identity.max_entry_bytes()

  # The limit for a caller no pipeline has authenticated is a host call's body.
  @unauthenticated_max_body_bytes Prima.HostAPI.max_body_bytes()

  # Sized for the 20 MB attachment cap the chat enforces (ThreadPaneLive's
  # max_file_size): attachments arrive base64-encoded through POST /mcp, so
  # 20 MB × 4/3 plus JSON envelope headroom. Granted only to a caller its
  # pipeline authenticated.
  @max_body_bytes 28_000_000

  # The private key marking a body read to its end.
  @read :cyfr_body_read

  @doc """
  The options of `CyfrWeb.Plugs.ParserErrors` every body is parsed under,
  with `extra` (`:jsonrpc`, say) added: urlencoded and JSON bodies through
  this reader, up to the cap `cap/1` names, a multipart body refused 415
  before any of it is read. The endpoint parses every path's body but
  `/mcp`'s with these, and `/mcp`'s pipeline its own.
  """
  @spec parser_options(keyword()) :: keyword()
  def parser_options(extra \\ []) do
    [
      refuse: {["multipart/*"], :multipart_refused},
      parsers: [:urlencoded, :json],
      pass: ["*/*"],
      json_decoder: Phoenix.json_library(),
      length: @max_body_bytes,
      body_reader: {__MODULE__, :read_body, []}
    ] ++ extra
  end

  @doc """
  The most bytes of `conn`'s body this reader reads: a host call's body
  (`Prima.HostAPI.max_body_bytes/0`) for a caller no pipeline has
  authenticated, the attachment allowance (28 MB) for one its pipeline
  has; never more than the webhook cap under `/hooks/*`, nor the
  directory's 16 KiB write-body limit under `/directory/*`, `/restore*`
  and `/certify/*`.
  """
  @spec cap(Plug.Conn.t()) :: pos_integer()
  def cap(conn) do
    Enum.min([
      @max_body_bytes,
      unauthenticated_cap(conn),
      webhook_cap(conn),
      directory_cap(conn)
    ])
  end

  @doc """
  Whether this reader has read `conn`'s body to its end.
  """
  @spec read?(Plug.Conn.t()) :: boolean()
  def read?(%Plug.Conn{private: %{@read => true}}), do: true
  def read?(_conn), do: false

  @doc """
  Plug.Parsers `:body_reader` callback.

  Returns `{:ok, body, conn}` or `{:more, chunk, conn}` exactly like
  `Plug.Conn.read_body/2`, the `:length` opt tightened to `cap/1`, so a
  body past it surfaces as 413. When the request path matches `/hooks/*`,
  every chunk is appended to `conn.assigns[:raw_body]` so downstream plugs
  can verify HMAC signatures against the complete body. A declared length
  above the cap reads nothing and answers `{:more, "", conn}`.
  """
  def read_body(conn, opts) do
    # Never above the parser's own `:length`: the smaller applies.
    length = min(Keyword.get(opts, :length, 8_000_000), cap(conn))

    opts =
      opts
      |> Keyword.put(:length, length)
      |> cap_read_length()

    if declared_over?(conn, length),
      do: {:more, "", conn},
      else: read_capped(conn, opts)
  end

  defp read_capped(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        conn = if hooks_path?(conn), do: append_raw_body(conn, body), else: conn
        {:ok, body, Plug.Conn.put_private(conn, @read, true)}

      {:more, chunk, conn} ->
        conn = if hooks_path?(conn), do: append_raw_body(conn, chunk), else: conn
        {:more, chunk, conn}

      {:error, _reason} = error ->
        error
    end
  end

  # Both families are recognized by the path the router routes on,
  # `path_info`, which drops empty segments: matched on the raw request
  # path instead, `//directory/…` would reach the directory's routes under
  # a longer limit than theirs.
  defp hooks_path?(%Plug.Conn{path_info: ["hooks" | _]}), do: true
  defp hooks_path?(_), do: false

  defp directory_path?(%Plug.Conn{path_info: [family | _]})
       when family in ["directory", "restore", "certify"],
       do: true

  defp directory_path?(_), do: false

  # Established by `CyfrWeb.Plugs.Authenticate`, which runs in a route's
  # pipeline, never before the endpoint's parse: a credential that
  # established no one leaves the context unauthenticated, so a header
  # alone never lifts the cap.
  defp authenticated?(%Plug.Conn{assigns: %{context: %Sanctum.Context{authenticated: true}}}),
    do: true

  defp authenticated?(_conn), do: false

  defp append_raw_body(conn, chunk) do
    existing = Map.get(conn.assigns, :raw_body, "")
    Plug.Conn.assign(conn, :raw_body, existing <> chunk)
  end

  # The webhook cap, configurable, under `/hooks/*`.
  defp webhook_cap(conn) do
    if hooks_path?(conn),
      do: Application.get_env(:cyfr, :webhook_max_body_bytes, @default_webhook_max_body_bytes),
      else: @max_body_bytes
  end

  # The directory's routes take no body past their largest entry.
  defp directory_cap(conn),
    do: if(directory_path?(conn), do: @directory_max_body_bytes, else: @max_body_bytes)

  # No body past a host call's from a caller no pipeline has authenticated.
  defp unauthenticated_cap(conn),
    do: if(authenticated?(conn), do: @max_body_bytes, else: @unauthenticated_max_body_bytes)

  # No read asks the adapter for more than the cap (`Plug.Conn.read_body/2`'s
  # 1 MB default above it).
  defp cap_read_length(opts) do
    Keyword.put(
      opts,
      :read_length,
      min(Keyword.get(opts, :read_length, 1_000_000), Keyword.fetch!(opts, :length))
    )
  end

  # A body its own `content-length` says is over the cap is refused unread.
  # Unparseable or repeated lengths are left to the adapter, which refuses
  # them, and the read stays bounded by the cap either way.
  defp declared_over?(conn, length) do
    case Plug.Conn.get_req_header(conn, "content-length") do
      [declared] ->
        case Integer.parse(declared) do
          {bytes, ""} -> bytes > length
          _other -> false
        end

      _none_or_many ->
        false
    end
  end
end
