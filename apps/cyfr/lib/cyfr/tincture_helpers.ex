# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.TinctureHelpers do
  @moduledoc """
  Shared helpers for tincture serving.

  All content reads (HTML entry, static assets, media discovery) flow
  through `Arca` so the Local FS adapter and any configured object-store
  adapter produce identical observable behaviour. Path validation, MIME
  selection, CSP nonce injection, and SDK injection live here; the storage
  hop is delegated to the adapter.

  The Cyfr SDK (`cyfr.js`) is compile-embedded so it never round-trips to
  storage at serve time. A per-request nonce secures the inline script via
  CSP without requiring `'unsafe-inline'`.
  """

  import Plug.Conn

  # arca:bypass-ok=C — compile-time embed of the SDK source. Runtime never
  # reads from disk for this; mix recompiles the module if the file changes.
  @sdk_source File.read!(Path.join(:code.priv_dir(:cyfr), "static/sdk/cyfr.js"))

  @doc """
  Resolve the athanor segment of a public tincture URL and build a public
  (unauthenticated) context for lookups in that athanor.

  The route segment is the athanor's slug: `@<namespace>` names a person's
  athanor, a bare slug a group's. Only an active athanor resolves; anything
  else is `{:error, :not_found}` — the URL never falls back to another
  athanor.

  This is the *serving / lookup* path (no execution). For building the scoped
  context that actually runs a tincture's catalyst, use
  `Sanctum.build_tincture_context/2` instead.

  Returns a `%Sanctum.Context{}` with `authenticated: false` so downstream
  APIs (`Arca.ComponentStorage`, `QueryHelpers.where_tenant`) work with a
  consistent type instead of ad-hoc maps. Visibility is still gated by
  whether an active public profile exists in that athanor (checked by
  `Sanctum.TinctureAccess.get_public/3`).
  """
  @spec build_public_context(String.t()) ::
          {:ok, Sanctum.Context.t()} | {:error, :not_found}
  def build_public_context(athanor_segment) when is_binary(athanor_segment) do
    case resolve_athanor(athanor_segment) do
      {:ok, athanor} ->
        {:ok, Sanctum.Context.build(athanor_id: athanor.id, scope: :athanor, authenticated: false)}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  The active athanor a public route segment names: `@<namespace>` → a
  person's athanor, `<slug>` → a group's. Archived or unknown → `:not_found`.
  """
  @spec resolve_athanor(String.t()) :: {:ok, Arca.Schemas.Athanor.t()} | {:error, :not_found}
  def resolve_athanor("@" <> namespace) when namespace != "" do
    active_only(Sanctum.Tenancy.Athanors.get_by_slug("person", namespace))
  end

  def resolve_athanor(slug) when is_binary(slug) and slug != "" do
    active_only(Sanctum.Tenancy.Athanors.get_by_slug("group", slug))
  end

  def resolve_athanor(_), do: {:error, :not_found}

  defp active_only({:ok, %{status: "active"} = athanor}), do: {:ok, athanor}
  defp active_only(_), do: {:error, :not_found}

  @doc """
  The route segment for an athanor: `@<slug>` for a person (their namespace),
  the slug itself for a group. Inverse of `resolve_athanor/1`.
  """
  @spec athanor_segment(Arca.Schemas.Athanor.t()) :: String.t()
  def athanor_segment(%{kind: "person", slug: slug}), do: "@" <> slug
  def athanor_segment(%{slug: slug}), do: slug

  @doc """
  Canonical tincture path: `/t/:athanor/:publisher/:name`, where `:athanor`
  is the athanor's route segment (`athanor_segment/1`).

  Single source of truth for the tincture URL shape — every server-side caller
  (controller base href, Prism shell iframe `src`, registry entry URL, the
  `tincture_visibility` public URL) composes this.
  """
  @spec tincture_path(String.t(), String.t(), String.t()) :: String.t()
  def tincture_path(athanor_segment, publisher, name)
      when is_binary(athanor_segment) and athanor_segment != "" do
    "/t/#{athanor_segment}/#{publisher}/#{name}"
  end

  @denylist ~w(data.db cyfr-manifest.json schema.sql)
  @allowed_extensions ~w(.html .js .css .json .svg .png .jpg .jpeg .gif .ico .woff .woff2 .ttf .eot .map)

  # Tincture media convention: fixed paths only, no globbing. We probe the
  # known slots via `Arca.exists?` so the same logic works against Local FS
  # and S3 (which has no real directories).
  @media_icon_candidates ~w(public/media/icon.svg public/media/icon.png)
  @media_preview_extensions ~w(svg png)
  # Mirrored by MAX_PREVIEWS in porta's tincture-store.ts — change both.
  @media_preview_count 6

  @doc """
  Discover media files via Arca, using the fixed `public/media/` convention.

  Returns relative paths (icon and previews) or nil/empty list when nothing
  matches. Worst case: ~14 `Arca.exists?` calls per tincture (one round-trip
  each on S3; one stat each on Local).
  """
  @spec discover_media_via_arca(Sanctum.Context.t(), [String.t()]) ::
          %{icon: String.t() | nil, previews: [String.t()]}
  def discover_media_via_arca(%Sanctum.Context{} = ctx, version_segs)
      when is_list(version_segs) do
    %{
      icon: discover_icon(ctx, version_segs),
      previews: discover_previews(ctx, version_segs)
    }
  end

  defp discover_icon(ctx, version_segs) do
    Enum.find(@media_icon_candidates, fn rel ->
      Arca.exists?(ctx, version_segs ++ String.split(rel, "/"))
    end)
  end

  defp discover_previews(ctx, version_segs) do
    Enum.flat_map(1..@media_preview_count, fn i ->
      Enum.find_value(@media_preview_extensions, [], fn ext ->
        rel = "public/media/preview-#{i}.#{ext}"
        if Arca.exists?(ctx, version_segs ++ String.split(rel, "/")), do: [rel]
      end)
    end)
  end

  @doc """
  Validate the entry filename declared by a tincture manifest.

  Returns `{:ok, entry_filename}` (with traversal checks already applied) or
  `:error` for entries that violate the denylist or contain unsafe characters.
  Resolution to actual storage segments is left to the caller — `serve_index/4`
  appends the entry to the tincture's `version_segs` and reads via Arca.
  """
  @spec resolve_entry(map()) :: {:ok, String.t()} | :error
  def resolve_entry(tincture) do
    entry = get_in(tincture.manifest, ["tincture", "entry"]) || "index.html"

    cond do
      entry in @denylist -> :error
      String.starts_with?(entry, ".") -> :error
      Cyfr.PathSafety.validate_relative_path(entry) != :ok -> :error
      true -> {:ok, entry}
    end
  end

  @doc """
  Serve a static asset from a tincture's directory via Arca.

  Validates path segments against denylist, dotfiles, traversal, and
  extension whitelist. Returns conn with file (Local: zero-copy via
  `Plug.Conn.send_file`; S3: in-memory body) or 404.
  """
  @spec serve_asset(
          Plug.Conn.t(),
          Sanctum.Context.t(),
          [String.t()],
          [String.t()],
          keyword()
        ) :: Plug.Conn.t()
  def serve_asset(conn, %Sanctum.Context{} = ctx, version_segs, asset_segs, opts \\ []) do
    cond do
      Enum.any?(asset_segs, fn s -> s in @denylist or String.starts_with?(s, ".") end) ->
        send_resp(conn, 404, "Not Found")

      Cyfr.PathSafety.validate_relative_path(Enum.join(asset_segs, "/")) != :ok ->
        send_resp(conn, 404, "Not Found")

      true ->
        filename = List.last(asset_segs) || ""
        ext = Path.extname(filename) |> String.downcase()

        if ext in @allowed_extensions do
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

          case Arca.serve_to_conn(conn, ctx, version_segs ++ asset_segs, []) do
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

  The SDK is injected as an inline `<script nonce="...">` so tincture authors
  get `window.cyfr` automatically. A per-request nonce is generated and added
  to the CSP `script-src` directive to authorize the inline script without
  requiring `'unsafe-inline'`.
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
    case Arca.get(ctx, version_segs ++ [entry]) do
      {:ok, content} ->
        nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        csp = String.replace(csp, "script-src 'self'", "script-src 'self' 'nonce-#{nonce}'")

        content = inject_head_tags(content, base_href, nonce)

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
end
