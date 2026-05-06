defmodule EmissaryWeb.Plugs.RawBodyReader do
  @moduledoc """
  Custom body reader for `Plug.Parsers` that preserves the raw request body
  *only* for the `/hooks/*` route family.

  Webhook signature verification (HMAC-SHA256) needs the exact bytes that the
  sender signed. Once `Plug.Parsers` has consumed the body, those bytes are
  gone — only `conn.body_params` remains. This reader buffers the raw bytes
  into `conn.assigns[:raw_body]` *before* parsing so the
  `EmissaryWeb.Plugs.VerifyWebhookSignature` plug can recover them.

  To avoid memory pressure on hot paths (`/mcp`, `/t/*`, `/api/*`, etc.) the
  bytes are NOT cached unless the request path begins with `/hooks/`.

  ## Per-feature length cap

  For `/hooks/*` paths we tighten the body length cap from the global 8 MB
  (set on `Plug.Parsers` at the endpoint) to a webhook-specific limit (default
  1 MB, configurable via `:webhook_max_body_bytes`). Webhooks rarely need
  >100 KB; the tighter cap reduces memory churn from misbehaving senders.

  Bodies larger than the cap cause `Plug.Conn.read_body/2` to return
  `{:more, _, _}` — `Plug.Parsers` then raises `Plug.Parsers.RequestTooLargeError`,
  which Phoenix maps to a 413 response.

  ## Chunked reads

  `Plug.Conn.read_body/2` returns `{:more, chunk, conn}` for partial reads
  (default `:read_length` is 1 MB). `Plug.Parsers` calls this body_reader
  iteratively and concatenates the chunks itself for parsing. This module
  *also* accumulates chunks into `conn.assigns[:raw_body]` so the cached
  copy matches the full body — required for HMAC verification of webhook
  payloads that exceed the per-chunk read length.
  """

  @default_webhook_max_body_bytes 1_048_576

  @doc """
  Plug.Parsers `:body_reader` callback.

  Returns `{:ok, body, conn}` or `{:more, chunk, conn}` exactly like
  `Plug.Conn.read_body/2`. When the request path matches `/hooks/*`, every
  chunk is appended to `conn.assigns[:raw_body]` so downstream plugs can
  verify HMAC signatures against the complete body, and the `:length` opt
  is tightened to the webhook-specific cap so oversized bodies surface as 413.
  """
  def read_body(conn, opts) do
    opts = maybe_cap_length_for_webhook(conn, opts)

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

  defp hooks_path?(%Plug.Conn{request_path: "/hooks/" <> _}), do: true
  defp hooks_path?(_), do: false

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
end
