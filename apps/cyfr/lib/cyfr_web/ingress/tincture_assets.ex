# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Ingress.TinctureAssets do
  @moduledoc """
  Tincture bytes over HTTP: a static asset, or the entry page with the
  SDK and a `<base>` injected into its head.

  Every read goes through `Arca` under the actor the authorized context
  projects, so the Local FS adapter and any configured object-store
  adapter produce identical observable behaviour. Which files and
  extensions may be served are the component domain's rules
  (`Compendium.tincture_asset_rules/0`); path validation, MIME selection,
  the response headers, the CSP nonce and the SDK injection live here.

  The Cyfr SDK (`cyfr.js`) is compile-embedded so it never round-trips to
  storage at serve time. A per-request nonce secures the inline script via
  CSP without requiring `'unsafe-inline'`.
  """

  import Plug.Conn

  @sdk_path Path.join(:code.priv_dir(:cyfr), "static/sdk/cyfr.js")
  @external_resource @sdk_path
  # arca:bypass-ok=C — compile-time embed of the SDK source. Runtime never
  # reads from disk for this; mix recompiles the module if the file changes.
  @sdk_source File.read!(@sdk_path)

  @doc """
  Serve a static asset from a tincture's directory via Arca.

  Validates path segments against the reserved files, dotfiles, traversal
  and the extension allowlist. Returns conn with the file (Local:
  zero-copy via `Plug.Conn.send_file`; S3: in-memory body) or 404.
  """
  @spec serve_asset(
          Plug.Conn.t(),
          Sanctum.Context.t(),
          [String.t()],
          [String.t()],
          keyword()
        ) :: Plug.Conn.t()
  def serve_asset(conn, %Sanctum.Context{} = ctx, version_segs, asset_segs, opts \\ []) do
    %{reserved_files: reserved, allowed_extensions: allowed} = Compendium.tincture_asset_rules()

    cond do
      Enum.any?(asset_segs, fn s -> s in reserved or String.starts_with?(s, ".") end) ->
        send_resp(conn, 404, "Not Found")

      Cyfr.PathSafety.validate_relative_path(Enum.join(asset_segs, "/")) != :ok ->
        send_resp(conn, 404, "Not Found")

      true ->
        filename = List.last(asset_segs) || ""
        ext = Path.extname(filename) |> String.downcase()

        if ext in allowed do
          # MIME.type/1 already returns "application/octet-stream" for unknown
          # extensions, so no fallback is needed.
          mime = MIME.type(String.trim_leading(ext, "."))

          cache_control =
            if Keyword.get(opts, :public, false),
              do: "public, max-age=3600",
              else: "private, max-age=3600"

          # ACAO:* unconditionally: the consumer is a sandboxed tincture
          # iframe with an opaque origin (`Origin: null`), whose fetch()es
          # could not read these responses otherwise. Authorization is the
          # capability URL (signed token on private paths), never the
          # requesting origin, so the wildcard grants nothing extra.
          conn =
            conn
            |> put_resp_header("x-content-type-options", "nosniff")
            |> put_resp_header("cache-control", cache_control)
            |> put_resp_content_type(mime)
            |> put_resp_header("access-control-allow-origin", "*")

          case Arca.serve_to_conn(
                 conn,
                 Sanctum.Context.actor(ctx),
                 version_segs ++ asset_segs,
                 []
               ) do
            {:ok, conn} -> conn
            {:error, _} -> send_resp(conn, 404, "Not Found")
          end
        else
          send_resp(conn, 404, "Not Found")
        end
    end
  end

  @doc """
  Read an HTML entry file via Arca, inject the Cyfr SDK and a `<base>` tag,
  and serve it.

  `base_href` is the tincture's root URL; the `<base>` names the entry's own
  directory under it, so a built entry at `dist/index.html` resolves its
  relative assets from `dist/`.

  The SDK is injected as an inline `<script nonce="...">` so tincture authors
  get `window.cyfr` automatically. A per-request nonce is generated and added
  to the CSP `script-src` directive to authorize the inline script without
  requiring `'unsafe-inline'`. A page with no `<head>` is served unchanged.
  """
  @spec serve_index(
          Plug.Conn.t(),
          Sanctum.Context.t(),
          [String.t()],
          String.t(),
          String.t(),
          String.t()
        ) :: Plug.Conn.t()
  def serve_index(conn, %Sanctum.Context{} = ctx, version_segs, entry, base_href, csp) do
    case Arca.get(Sanctum.Context.actor(ctx), version_segs ++ Path.split(entry)) do
      {:ok, content} ->
        nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        csp = String.replace(csp, "script-src 'self'", "script-src 'self' 'nonce-#{nonce}'")

        content = inject_head_tags(content, base_href <> entry_dir(entry), nonce)

        conn
        |> put_resp_header("content-security-policy", csp)
        |> put_resp_header("x-content-type-options", "nosniff")
        # A bare MIME: `put_resp_content_type/2` appends `; charset=utf-8`
        # itself, so spelling it here served every tincture index as
        # `text/html; charset=utf-8; charset=utf-8`. The asset path next door
        # passes a bare type correctly.
        |> put_resp_content_type("text/html")
        |> send_resp(200, content)

      {:error, _} ->
        send_resp(conn, 404, "Not Found")
    end
  end

  defp entry_dir(entry) do
    case Path.dirname(entry) do
      "." -> ""
      dir -> dir <> "/"
    end
  end

  @head_re ~r/(<head(?:\s[^>]*)?>)/
  defp inject_head_tags(html, href, nonce) do
    escaped_href = Plug.HTML.html_escape(href)

    injection =
      "\\1\n<base href=\"#{escaped_href}\">\n<script nonce=\"#{nonce}\">#{@sdk_source}</script>"

    if Regex.match?(@head_re, html) do
      Regex.replace(@head_re, html, injection, global: false)
    else
      html
    end
  end
end
