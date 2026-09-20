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
    case Sanctum.Tenancy.Athanors.by_route_slug(athanor_segment) do
      {:ok, athanor} ->
        {:ok,
         Sanctum.Context.build(athanor_id: athanor.id, scope: :athanor, authenticated: false)}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Canonical tincture path: `/t/:athanor/:publisher/:name`, where `:athanor`
  is the athanor's route segment (`Sanctum.Tenancy.Athanors.route_slug/1`).

  The shape itself is `Cyfr.TinctureUrl.path/3`, where both sides of the
  URL read it; this is the serving module's spelling of the same call.
  """
  @spec tincture_path(String.t(), String.t(), String.t()) :: String.t()
  defdelegate tincture_path(athanor_segment, publisher, name), to: Cyfr.TinctureUrl, as: :path

  @denylist ["data.db", Compendium.ComponentPath.manifest_name(), "schema.sql"]
  @allowed_extensions ~w(.html .js .css .json .svg .png .jpg .jpeg .gif .ico .woff .woff2 .ttf .eot .map)

  # The raster set the CSAM launch constraint blocks in the two DISCOVERY
  # slots (icon/preview): a tincture whose discovered media names one of
  # these is dropped from the listing until hash matching (PhotoDNA)
  # ships. Deliberately narrower than the serve gate above — a directly
  # referenced raster asset inside an operator-installed app still serves;
  # the constraint is on what the registry SURFACES, not on what an
  # installed page may contain. `.webp` is blocked here and absent from
  # the serve gate, so it can neither be discovered nor served.
  @blocked_raster_extensions ~w(.png .jpg .jpeg .gif .webp)

  @doc "Extensions the asset serve gate honors — the one spelling."
  @spec allowed_extensions() :: [String.t()]
  def allowed_extensions, do: @allowed_extensions

  @doc "The raster set the listing's CSAM launch constraint blocks."
  @spec blocked_raster_extensions() :: [String.t()]
  def blocked_raster_extensions, do: @blocked_raster_extensions

  @doc """
  Image extensions a console page may build an asset URL for: vector plus
  every servable raster — derived from the serve gate, so the client-side
  fast reject and the server-side gate cannot drift.
  """
  @spec image_extensions() :: [String.t()]
  def image_extensions do
    [".svg" | @blocked_raster_extensions] |> Enum.filter(&(&1 in @allowed_extensions))
  end

  @doc """
  Whether a `tincture.connect` entry is a bare domain with an optional
  `*.` prefix. Used by manifest validation and CSP generation. Rejects
  wildcards without a domain, IP addresses, paths, ports, schemes, and
  trailing characters outside the domain grammar.
  """
  @spec valid_connect_domain?(term()) :: boolean()
  def valid_connect_domain?(domain) when is_binary(domain) do
    base = String.replace_prefix(domain, "*.", "")

    cond do
      domain == "*" -> false
      String.contains?(domain, "/") -> false
      String.contains?(domain, ":") -> false
      String.contains?(domain, " ") -> false
      not Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}\z/, base) -> false
      true -> true
    end
  end

  def valid_connect_domain?(_), do: false

  # Tincture media convention: fixed paths only, no globbing. We probe the
  # known slots via `Arca.exists?` so the same logic works against Local FS
  # and S3 (which has no real directories). This module is the convention's
  # one spelling — the scaffolder writes its placeholders through the
  # functions below, so what it writes, discovery finds.
  @media_icon_candidates ~w(public/media/icon.svg public/media/icon.png)
  @media_preview_extensions ~w(svg png)
  @media_preview_count 6

  @doc "The manifest path the entry lives at: `tincture.entry`."
  @spec entry_field() :: [String.t()]
  def entry_field, do: ["tincture", "entry"]

  @doc "What a tincture serves when its manifest names no entry."
  @spec default_entry() :: String.t()
  def default_entry, do: "index.html"

  @doc """
  The entry a manifest names, or the default — one reading, for publish and
  for serve.

  The same entry validation applies during publishing, indexing,
  and serving.
  """
  @spec entry_of(map()) :: {:ok, String.t()} | {:error, String.t()}
  def entry_of(manifest) when is_map(manifest) do
    manifest |> get_in(entry_field()) |> validate_entry()
  end

  @spec validate_entry(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_entry(nil), do: {:ok, default_entry()}
  def validate_entry(""), do: {:ok, default_entry()}

  # Path safety answers first: it covers traversal, absolute paths and null
  # bytes, and its refusals name what is actually wrong. A `../escape.html`
  # begins with a dot, so a dotfile check placed above would refuse it for
  # the least useful of its several reasons.
  def validate_entry(entry) when is_binary(entry) do
    with :ok <- path_safe(entry) do
      cond do
        entry in @denylist ->
          {:error, "entry must not be a reserved file (#{Enum.join(@denylist, ", ")})"}

        String.starts_with?(entry, ".") ->
          {:error, "entry must not be a dotfile"}

        true ->
          {:ok, entry}
      end
    end
  end

  def validate_entry(_other), do: {:error, "entry must be a string"}

  # Branch on the typed refusal, independently of message wording.
  defp path_safe(entry) do
    case Cyfr.PathSafety.validate_relative_path(entry) do
      :ok ->
        :ok

      {:error, {:null_bytes, _}} ->
        {:error, "entry must not contain null bytes"}

      {:error, {:absolute_path, _}} ->
        {:error, "entry must be a relative path"}

      {:error, {reason, _}} when reason in [:dot_segment, :encoded_dots] ->
        {:error, "entry must not contain '..'"}

      {:error, {_reason, message}} ->
        {:error, "entry rejected: #{message}"}
    end
  end

  @doc "The media directory inside a tincture version, as segments."
  @spec media_dir() :: [String.t()]
  def media_dir, do: ["public", "media"]

  @doc "The default icon slot the scaffolder fills, as segments."
  @spec default_icon() :: [String.t()]
  def default_icon, do: media_dir() ++ ["icon.svg"]

  @doc "The default preview slot the scaffolder fills, as segments."
  @spec default_preview() :: [String.t()]
  def default_preview, do: media_dir() ++ ["preview-1.svg"]

  @doc "How many preview slots the picker card shows."
  @spec preview_count() :: pos_integer()
  def preview_count, do: @media_preview_count

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
      Arca.exists?(Sanctum.Context.actor(ctx), version_segs ++ String.split(rel, "/"))
    end)
  end

  defp discover_previews(ctx, version_segs) do
    Enum.flat_map(1..@media_preview_count, fn i ->
      Enum.find_value(@media_preview_extensions, [], fn ext ->
        rel = "public/media/preview-#{i}.#{ext}"

        if Arca.exists?(Sanctum.Context.actor(ctx), version_segs ++ String.split(rel, "/")),
          do: [rel]
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
    case entry_of(tincture.manifest) do
      {:ok, entry} -> {:ok, entry}
      {:error, _message} -> :error
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
