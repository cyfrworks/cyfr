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

  For `/hooks/*` paths we tighten the body length cap from the endpoint's
  (the `:length` set on `Plug.Parsers`) to a webhook-specific limit (default
  1 MB, configurable via `:webhook_max_body_bytes`). Webhooks rarely need
  >100 KB; the tighter cap reduces memory churn from misbehaving senders.

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

  ## `/mcp`'s body before a caller is established

  `/mcp`'s body is parsed in its own pipeline, after the transport's rate
  limit and `CyfrWeb.Plugs.Authenticate` (`Emissary.Router`), never by
  the endpoint. A request whose context is not authenticated — no
  credential, or one that established no one — is bounded to a host
  call's body (`Prima.HostAPI.max_body_bytes/0`, 1 MiB) the same way; an
  authenticated caller keeps the endpoint's length, which carries the
  chat's base64 attachments.

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

  # `/mcp`'s limit before a caller is established is a host call's body.
  @anonymous_mcp_max_body_bytes Prima.HostAPI.max_body_bytes()

  # Sized for the 20 MB attachment cap the chat enforces (ThreadPaneLive's
  # max_file_size): attachments arrive base64-encoded through POST /mcp, so
  # 20 MB × 4/3 plus JSON envelope headroom.
  @max_body_bytes 28_000_000

  @doc """
  The options of `CyfrWeb.Plugs.ParserErrors` every body is parsed under,
  with `extra` (`:jsonrpc`, say) added: urlencoded and JSON bodies through
  this reader, up to the endpoint's length, a multipart body refused 415
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
  Plug.Parsers `:body_reader` callback.

  Returns `{:ok, body, conn}` or `{:more, chunk, conn}` exactly like
  `Plug.Conn.read_body/2`. When the request path matches `/hooks/*`, every
  chunk is appended to `conn.assigns[:raw_body]` so downstream plugs can
  verify HMAC signatures against the complete body, and the `:length` opt
  is tightened to the webhook-specific cap so oversized bodies surface as 413.
  Under `/directory/*`, `/restore*` and `/certify/*` the `:length` opt is tightened to
  the directory's 16 KiB write-body limit the same way, and under `/mcp`,
  for a caller not authenticated, to a host call's body. A declared
  length above the cap reads nothing and answers `{:more, "", conn}`.
  """
  def read_body(conn, opts) do
    opts =
      conn
      |> maybe_cap_length_for_webhook(opts)
      |> cap_length_for_directory(conn)
      |> cap_length_for_anonymous_mcp(conn)
      |> cap_read_length()

    if declared_over?(conn, Keyword.fetch!(opts, :length)),
      do: {:more, "", conn},
      else: read_capped(conn, opts)
  end

  defp read_capped(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        conn = if hooks_path?(conn), do: append_raw_body(conn, body), else: conn
        {:ok, body, conn}

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
  # the endpoint's own limit.
  defp hooks_path?(%Plug.Conn{path_info: ["hooks" | _]}), do: true
  defp hooks_path?(_), do: false

  defp directory_path?(%Plug.Conn{path_info: [family | _]})
       when family in ["directory", "restore", "certify"],
       do: true

  defp directory_path?(_), do: false

  defp mcp_path?(%Plug.Conn{path_info: ["mcp" | _]}), do: true
  defp mcp_path?(_), do: false

  # Established by `CyfrWeb.Plugs.Authenticate`, which runs before `/mcp`'s
  # body is read: a credential that established no one leaves the context
  # unauthenticated, so a header alone never lifts the cap.
  defp authenticated?(%Plug.Conn{assigns: %{context: %Sanctum.Context{authenticated: true}}}),
    do: true

  defp authenticated?(_conn), do: false

  defp append_raw_body(conn, chunk) do
    existing = Map.get(conn.assigns, :raw_body, "")
    Plug.Conn.assign(conn, :raw_body, existing <> chunk)
  end

  # Tighten `Plug.Parsers`'s `:length` for webhook paths. Use the smaller of
  # the existing `:length` and our webhook cap so we never *raise* the limit
  # above whatever was configured upstream.
  defp maybe_cap_length_for_webhook(conn, opts) do
    if hooks_path?(conn) do
      cap = Application.get_env(:cyfr, :webhook_max_body_bytes, @default_webhook_max_body_bytes)
      existing = Keyword.get(opts, :length, 8_000_000)
      Keyword.put(opts, :length, min(existing, cap))
    else
      opts
    end
  end

  # `/mcp` takes no body past a host call's from a caller not established,
  # whatever the endpoint's own cap: the smaller of the two applies.
  defp cap_length_for_anonymous_mcp(opts, conn) do
    if mcp_path?(conn) and not authenticated?(conn) do
      existing = Keyword.get(opts, :length, 8_000_000)
      Keyword.put(opts, :length, min(existing, @anonymous_mcp_max_body_bytes))
    else
      opts
    end
  end

  # No read asks the adapter for more than the cap (`Plug.Conn.read_body/2`'s
  # 1 MB default above it).
  defp cap_read_length(opts) do
    length = Keyword.get(opts, :length, 8_000_000)

    opts
    |> Keyword.put(:length, length)
    |> Keyword.put(:read_length, min(Keyword.get(opts, :read_length, 1_000_000), length))
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

  # The directory's routes take no body past their largest entry, whatever
  # the endpoint's own cap: the smaller of the two applies.
  defp cap_length_for_directory(opts, conn) do
    if directory_path?(conn) do
      existing = Keyword.get(opts, :length, 8_000_000)
      Keyword.put(opts, :length, min(existing, @directory_max_body_bytes))
    else
      opts
    end
  end
end
