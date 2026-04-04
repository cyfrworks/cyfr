defmodule PrismWeb.TinctureHelpers do
  @moduledoc """
  Shared helpers for tincture serving (public and authenticated access).

  Centralizes path validation, asset serving, and entry-point resolution
  for the unified `/t` route surface. Public visibility is DB-backed
  via `Sanctum.TinctureVisibility`.

  The Cyfr SDK (`cyfr.js`) is automatically injected into every tincture's
  HTML at serve time — tincture authors get `window.cyfr` without needing
  a `<script>` tag. A per-request nonce secures the inline script via CSP.
  """

  import Plug.Conn

  # Load the SDK source at compile time so there's no runtime file I/O.
  @sdk_source File.read!(Path.join(:code.priv_dir(:cyfr), "static/sdk/cyfr.js"))

  @doc """
  Build a public (unauthenticated) context for tincture lookups.

  Returns a `%Sanctum.Context{}` with `authenticated: false` so downstream
  APIs (`Arca.ComponentStorage`, `QueryHelpers.where_tenant`) work with a
  consistent type instead of ad-hoc maps.

  Core mode: `org_id: ""` (matches Core components via QueryHelpers.where_tenant).
  Arx mode: fails closed with `arx_unresolved: true` until hostname→org resolution is implemented.
  """
  @spec build_public_context() :: Sanctum.Context.t()
  def build_public_context do
    case Application.get_env(:cyfr, :edition, :core) do
      :arx ->
        # Arx public routes fail closed until hostname→org resolution (Arx_Roadmap.md 2.1h).
        # org_id stays nil — TinctureAccess.get_public rejects nil org_id (fail closed).
        Sanctum.Context.build(org_id: nil, project_id: "default", authenticated: false)

      _ ->
        Sanctum.Context.build(org_id: "", project_id: "default", authenticated: false)
    end
  end

  @doc """
  Build the canonical shell entry URL for a tincture.

  Returns the versionless index route `/t/:publisher/:name` which is handled
  by `TinctureController.index/2`. This route sets security-critical CSP headers
  (`connect-src 'none'` for shell iframes). The `entry` argument is accepted for
  API compatibility but not included in the URL — the controller resolves the
  entry file from the manifest.

  Centralized so TinctureRegistry and any future callers use the same
  route prefix. Arx hostname-based URLs can be added here later.
  """
  @spec entry_url(String.t(), String.t(), String.t()) :: String.t()
  def entry_url(publisher, name, _entry) do
    "/t/#{publisher}/#{name}"
  end

  @denylist ~w(data.db cyfr-manifest.json schema.sql)
  @allowed_extensions ~w(.html .js .css .json .svg .png .jpg .jpeg .gif .ico .woff .woff2 .ttf .eot .map)

  @doc """
  Resolve and validate the entry file path from a tincture manifest.

  Applies containment check to prevent path traversal via manifest entry field.
  Returns `{:ok, resolved_path}` or `:error`.
  """
  @spec resolve_entry(map()) :: {:ok, String.t()} | :error
  def resolve_entry(tincture) do
    entry = get_in(tincture.manifest, ["tincture", "entry"]) || "index.html"

    if entry in @denylist or String.starts_with?(entry, ".") do
      :error
    else
      resolve_within(tincture.dir, [entry])
    end
  end

  @doc """
  Serve a static asset from a tincture's directory.

  Validates path segments against denylist, dotfiles, traversal, extension
  whitelist, and containment. Returns conn with file or 404.
  """
  @spec serve_asset(Plug.Conn.t(), String.t(), [String.t()], keyword()) :: Plug.Conn.t()
  def serve_asset(conn, base_dir, segments, opts \\ []) do
    cond do
      # Check ALL segments for denylist and dotfiles (not just the last)
      Enum.any?(segments, fn s ->
        s in @denylist or String.starts_with?(s, ".")
      end) ->
        send_resp(conn, 404, "Not Found")

      # Path traversal / null byte / backslash check on all segments
      Enum.any?(segments, fn s ->
        s == ".." or String.contains?(s, "\0") or String.contains?(s, "\\")
      end) ->
        send_resp(conn, 404, "Not Found")

      true ->
        case resolve_within(base_dir, segments) do
          {:ok, resolved} ->
            filename = List.last(segments) || ""
            ext = Path.extname(filename) |> String.downcase()

            if ext in @allowed_extensions do
              mime = MIME.type(ext |> String.trim_leading(".")) || "application/octet-stream"

              cache_control =
                if Keyword.get(opts, :public, false),
                  do: "public, max-age=3600",
                  else: "private, max-age=3600"

              conn =
                conn
                |> put_resp_header("x-content-type-options", "nosniff")
                |> put_resp_header("cache-control", cache_control)
                |> put_resp_content_type(mime)

              # Sandboxed iframes (allow-scripts, no allow-same-origin) have an
              # opaque origin, so module script / fetch requests require CORS.
              # Enable for public tinctures and signed-token assets (iframes).
              conn =
                if Keyword.get(opts, :cors, false) do
                  put_resp_header(conn, "access-control-allow-origin", "*")
                else
                  conn
                end

              send_file(conn, 200, resolved)
            else
              send_resp(conn, 404, "Not Found")
            end

          :error ->
            send_resp(conn, 404, "Not Found")
        end
    end
  end

  @doc """
  Read an HTML entry file, inject the Cyfr SDK and a `<base>` tag, and serve it.

  The SDK is injected as an inline `<script nonce="...">` so tincture authors
  get `window.cyfr` automatically. A per-request nonce is generated and added
  to the CSP `script-src` directive to authorize the inline script without
  requiring `'unsafe-inline'`.

  The `<base href="/t/pub/name/">` tag fixes relative URL resolution — without
  it, browsers resolve `./app.js` against `/t/pub/` instead of `/t/pub/name/`.
  """
  @spec serve_index(Plug.Conn.t(), String.t(), String.t(), String.t()) :: Plug.Conn.t()
  def serve_index(conn, file_path, base_href, csp) do
    case File.read(file_path) do
      {:ok, content} ->
        nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        csp = String.replace(csp, "script-src 'self'", "script-src 'self' 'nonce-#{nonce}'")

        content =
          content
          |> inject_head_tags(base_href, nonce)

        conn
        |> put_resp_header("content-security-policy", csp)
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_content_type("text/html; charset=utf-8")
        |> send_resp(200, content)

      {:error, _} ->
        send_resp(conn, 404, "Not Found")
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

  # Resolve a path within a base directory, ensuring containment.
  defp resolve_within(base_dir, segments) do
    relative = Path.join(segments)
    file_path = Path.join(base_dir, relative)
    resolved = Path.expand(file_path)
    base = Path.expand(base_dir)

    if String.starts_with?(resolved, base <> "/") and File.regular?(resolved) do
      {:ok, resolved}
    else
      :error
    end
  end
end
