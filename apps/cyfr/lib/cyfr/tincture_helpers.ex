defmodule Cyfr.TinctureHelpers do
  @moduledoc """
  Shared helpers for tincture serving.

  Centralizes path validation, asset serving, entry-point resolution, and
  SDK injection for the `/t` route surface. Endpoint-independent — used by
  both EmissaryWeb (tincture HTTP serving) and PrismWeb (ShellLive browser).

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
  Arx mode: fails closed with `org_id: nil` until hostname→org resolution is implemented.
  """
  @spec build_public_context() :: Sanctum.Context.t()
  def build_public_context do
    case Application.get_env(:cyfr, :edition, :core) do
      :arx ->
        Sanctum.Context.build(org_id: nil, project_id: "default", authenticated: false)

      _ ->
        Sanctum.Context.build(org_id: "", project_id: "default", authenticated: false)
    end
  end

  @doc """
  Build the canonical entry URL for a tincture.

  Returns the versionless index route `/t/:publisher/:name`. The `entry`
  argument is accepted for API compatibility but not included in the URL —
  the controller resolves the entry file from the manifest.
  """
  @spec entry_url(String.t(), String.t(), String.t()) :: String.t()
  def entry_url(publisher, name, _entry) do
    "/t/#{publisher}/#{name}"
  end

  @denylist ~w(data.db cyfr-manifest.json schema.sql)
  @allowed_extensions ~w(.html .js .css .json .svg .png .jpg .jpeg .gif .ico .woff .woff2 .ttf .eot .map)

  # Tincture media convention: fixed paths only, no scanning. The picker
  # checks `public/media/icon.{svg,png}` and `public/media/preview-{1..6}.{svg,png}`.
  # SVG is preferred (scales crisply from 20px sidebar to 160px carousel card);
  # PNG is the fallback for authors whose tools don't export SVG.
  @media_icon_candidates ~w(public/media/icon.svg public/media/icon.png)
  @media_preview_extensions ~w(svg png)
  @media_preview_count 6

  @doc """
  Discover media files in a tincture's version directory using the fixed
  `public/media/` convention. Returns relative paths (icon and previews) or
  nil/empty list when nothing matches. Uses `File.regular?/1` checks against
  fixed slot paths only — no `File.ls`, no globbing, no sorting.

  Worst case: ~14 stat calls per tincture, all fast.
  """
  @spec discover_media(String.t()) :: %{icon: String.t() | nil, previews: [String.t()]}
  def discover_media(version_dir) when is_binary(version_dir) do
    %{
      icon: discover_icon(version_dir),
      previews: discover_previews(version_dir)
    }
  end

  def discover_media(_), do: %{icon: nil, previews: []}

  defp discover_icon(version_dir) do
    Enum.find(@media_icon_candidates, fn rel ->
      File.regular?(Path.join(version_dir, rel))
    end)
  end

  defp discover_previews(version_dir) do
    Enum.flat_map(1..@media_preview_count, fn i ->
      Enum.find_value(@media_preview_extensions, [], fn ext ->
        rel = "public/media/preview-#{i}.#{ext}"
        if File.regular?(Path.join(version_dir, rel)), do: [rel]
      end)
    end)
  end

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
      Enum.any?(segments, fn s ->
        s in @denylist or String.starts_with?(s, ".")
      end) ->
        send_resp(conn, 404, "Not Found")

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
