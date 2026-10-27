# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.TinctureAssets do
  @moduledoc """
  Tincture bytes over HTTP: one file of a tincture version — its entry
  page with the SDK and a `<base>` injected into its head, another page,
  or an asset — with the headers every tincture response carries.

  Every read goes through `Arca` under the actor the authorized context
  projects, so the Local FS adapter and any configured object-store
  adapter produce identical observable behaviour. Which files may be
  served and with which type are the component domain's rules
  (`Compendium.tincture_asset_rules/0`, `Compendium.tincture_served_types/0`),
  and a document's Content Security Policy with its `sandbox` directive is
  derived whole from the version's declaration by the frame's rules
  (`Compendium.tincture_frame_policy/2`);
  path validation, the headers, the nonce, compression and the SDK
  injection live here.

  ## Every response

    * `Referrer-Policy: no-referrer`, so no URL of a tincture — a private
      one's carries its asset credential — leaves in a `Referer`;
    * `Cache-Control` as the route asks: `public` for a public tincture's
      files, `no-cache` for its address (which follows its latest
      version), and `private` with `max-age` never above the asset
      credential's remaining seconds for a private one's. Bytes a browser
      already holds are not recalled: a retired credential refuses the
      next fetch, and a cached copy serves until its `max-age` runs out;
    * `Access-Control-Allow-Origin: *`: the consumer is a sandboxed frame
      with an opaque origin (`Origin: null`), whose fetches could not read
      these responses otherwise. What authorizes a read is the URL — a
      public tincture's address, or the credential in a private one's path
      — never the requesting origin, so the wildcard grants nothing;
    * compression (`gzip`, when the request accepts it) for text, scripts,
      JSON and WebAssembly up to 16 MiB, with
      `Vary: Accept-Encoding`.

  ## Every document

  An HTML file is served with the policy derived from the declaration, a
  fresh nonce and a `sandbox` directive opening what the declared frame
  capabilities open and nothing else, so a document navigated to directly
  — outside the shell's frame — is never a first-party page of this
  origin. The entry page is also given the SDK, compile-embedded so it
  never round-trips to storage, as an inline script under the nonce.

  A canvas holds no page here: its page is its entry served at its own
  route under the canvas's policy (`Emissary.Web.CanvasController`, which
  assembles it with `canvas_page/5`), and an HTML file of a canvas version
  is not found here, so no page of a canvas is ever served under the
  ordinary policy. A version whose placement cannot be read, its
  declaration refused by today's rules, is served as a canvas version is.
  The SDK a canvas page loads is served at one path named by its digest
  (`canvas_sdk_path/0`), since no inline script runs in a canvas page.
  """

  import Plug.Conn

  @sdk_path Path.join(:code.priv_dir(:cyfr), "static/sdk/cyfr.js")
  @external_resource @sdk_path
  # arca:bypass-ok=C — compile-time embed of the SDK source. Runtime never
  # reads from disk for this; mix recompiles the module if the file changes.
  @sdk_source File.read!(@sdk_path)
  @sdk_digest :sha256 |> :crypto.hash(@sdk_source) |> Base.encode16(case: :lower)

  # The `<head>` start tag an entry page's injected tags follow.
  @head_re ~r/(<head(?:\s[^>]*)?>)/

  # Compressed on the fly, so bounded: a larger file is sent as it is
  # stored rather than holding a request's CPU for it.
  @compress_limit 16 * 1024 * 1024
  @compressible_prefixes ["text/"]
  @compressible_types ~w(application/json application/wasm image/svg+xml model/gltf+json)

  @typedoc """
  How a response may be cached: a public tincture's for the given seconds,
  or a private one's for at most the seconds its credential has left.
  """
  @type cache :: {:public, pos_integer()} | {:private, pos_integer()} | :revalidate

  @doc """
  Serve `file` (its segments inside the version) of `tincture`, a row
  carrying its `segments` and decoded `manifest`, under `ctx`.

  Options: `cache:` (`t:cache/0`, required), and `base:` — the URL every
  file of the version is served under, ending in `/`, from which the entry
  page's `<base>` names the entry's own directory, so a built entry at
  `dist/index.html` resolves its relative assets from `dist/`.

  A version holds pages only when the frame's rules read its declaration
  and its placement is not `canvas`. Any other version — a canvas, or one
  whose declaration today's rules refuse — serves no document: its `.html`
  file answers the not-found refusal below, as an `.htm` file of any
  version does, and every other file is served as its type.

  A reserved file, a dotfile, an unsafe path, a type the rules do not
  serve and an absent file all answer the same JSON `not_found` refusal
  (`CyfrWeb.ApiError`).
  """
  @spec serve(Plug.Conn.t(), Sanctum.Context.t(), map(), [String.t()], keyword()) ::
          Plug.Conn.t()
  def serve(conn, %Sanctum.Context{} = ctx, tincture, file, opts) when is_list(file) do
    cache = Keyword.fetch!(opts, :cache)

    with :ok <- servable(file),
         {:ok, type} <- served_type(file) do
      conn = headers(conn, cache)
      path = Enum.join(file, "/")

      cond do
        type == "text/html" and not holds_pages?(tincture) ->
          not_found(conn)

        entry_document?(tincture, path) ->
          base = Keyword.fetch!(opts, :base) <> entry_dir(path)
          document(conn, ctx, tincture, file, base)

        type == "text/html" ->
          document(conn, ctx, tincture, file, nil)

        compressible?(type) ->
          read_and_send(conn, ctx, tincture, file, type)

        true ->
          conn = put_resp_header(conn, "content-type", type)

          case Arca.serve_to_conn(conn, Sanctum.Context.actor(ctx), tincture.segments ++ file, []) do
            {:ok, conn} -> conn
            {:error, _} -> not_found(conn)
          end
      end
    else
      _refused -> not_found(conn)
    end
  end

  # A document's `Content-Security-Policy`: the frame's rules' derivation
  # from the version's manifest under `nonce`, with a `sandbox` directive
  # opening exactly what the declared frame capabilities open. A document
  # is served only for a version whose manifest is a decoded object
  # (`holds_pages?/1`).
  @spec csp(map(), String.t()) :: String.t()
  defp csp(manifest, nonce) when is_map(manifest) and is_binary(nonce),
    do: Compendium.tincture_frame_policy(manifest, %{endpoint: endpoint_origin(), nonce: nonce})

  @doc """
  The endpoint's origin as a tincture document's policy names it, from the
  deployment's origin (`Sanctum.origin/0`): `scheme://host[:port]`, an IPv6
  host in brackets, the port only when it is not the scheme's own. A
  canvas's page names it too (`Emissary.Web.CanvasController`).
  """
  @spec endpoint_origin() :: String.t()
  def endpoint_origin do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(Sanctum.origin())
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host

    if port && port != URI.default_port(scheme),
      do: "#{scheme}://#{host}:#{port}",
      else: "#{scheme}://#{host}"
  end

  # ---------------------------------------------------------------------------
  # A canvas's page and the SDK it loads
  # ---------------------------------------------------------------------------

  @doc """
  The one path the SDK a canvas page loads is served at:
  `/_c/v1/sdk/<sha-256 of its bytes, lowercase hex>.js`, under the canvas
  page prefix (`Prima.TinctureWire.page_prefix/0`). A canvas page's policy
  names exactly this path (`Compendium.tincture_canvas_page_csp/1`), and
  new bytes are a new path.
  """
  @spec canvas_sdk_path() :: String.t()
  def canvas_sdk_path, do: Prima.TinctureWire.page_prefix() <> "sdk/" <> @sdk_digest <> ".js"

  @doc "The SDK's bytes, as `canvas_sdk_path/0` serves them: the bundle every tincture page holds."
  @spec canvas_sdk() :: binary()
  def canvas_sdk, do: @sdk_source

  @doc """
  A canvas's page: the version's entry document (`entry`, its path inside
  the version), read through `Arca` under `ctx` as every served file is,
  with `<base href="base">` and `<script src="sdk_src"></script>` put
  first in its `<head>`, in that order and with no nonce, since no inline
  script runs in a canvas page. An entry with no `<head>` is answered as
  it is. `:error` when the entry cannot be read.
  """
  @spec canvas_page(Sanctum.Context.t(), map(), String.t(), String.t(), String.t()) ::
          {:ok, binary()} | :error
  def canvas_page(%Sanctum.Context{} = ctx, tincture, entry, base, sdk_src)
      when is_binary(entry) and is_binary(base) and is_binary(sdk_src) do
    case Arca.get(Sanctum.Context.actor(ctx), tincture.segments ++ String.split(entry, "/")) do
      {:ok, content} ->
        tags =
          ~s(<base href="#{Plug.HTML.html_escape(base)}">) <>
            ~s(<script src="#{Plug.HTML.html_escape(sdk_src)}"></script>)

        {:ok, Regex.replace(@head_re, content, &(&1 <> tags), global: false)}

      {:error, _} ->
        :error
    end
  end

  # ---------------------------------------------------------------------------
  # The file, and what it is served as
  # ---------------------------------------------------------------------------

  defp servable(file) do
    %{reserved_files: reserved} = Compendium.tincture_asset_rules()

    cond do
      file == [] -> :error
      Enum.any?(file, &(&1 in reserved or String.starts_with?(&1, "."))) -> :error
      Prima.PathSafety.validate_relative_path(Enum.join(file, "/")) != :ok -> :error
      true -> :ok
    end
  end

  defp served_type(file) do
    extension = file |> List.last() |> Path.extname() |> String.downcase()
    Map.fetch(Compendium.tincture_served_types(), extension)
  end

  # Whether `path` is the tincture's entry page. Only a version that holds
  # pages has one: a canvas's entry is served at its own route, and a
  # version whose placement cannot be read is held as a canvas.
  defp entry_document?(tincture, path),
    do: Compendium.tincture_entry(tincture) == {:ok, path} and holds_pages?(tincture)

  # Whether the version holds pages: only when its manifest is a decoded
  # object, the frame's rules read its declaration
  # (`Compendium.tincture_declaration/1`) and its placement is not
  # `canvas`. A declaration today's rules refuse fails closed, held as a
  # canvas, whatever its raw placement says, and so does a manifest that is
  # not a map, which the declaration's parse would read as an empty one.
  defp holds_pages?(%{manifest: manifest}) when is_map(manifest) do
    case Compendium.tincture_declaration(manifest) do
      {:ok, %{frame: %{placement: placement}}} -> placement != "canvas"
      {:error, _refused} -> false
    end
  end

  defp holds_pages?(_no_manifest), do: false

  defp headers(conn, cache) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("cache-control", cache_control(cache))
    |> put_resp_header("access-control-allow-origin", "*")
    # Framed by the shell on this same origin; the document's own
    # `frame-ancestors` says the same to browsers that read it.
    |> put_resp_header("x-frame-options", "SAMEORIGIN")
  end

  defp cache_control({visibility, seconds})
       when visibility in [:public, :private] and is_integer(seconds) and seconds > 0,
       do: "#{visibility}, max-age=#{seconds}"

  defp cache_control(:revalidate), do: "no-cache"

  # A page of the version: the policy under a fresh nonce, and — for the
  # entry — the `<base>` and the SDK under that nonce. A page with no
  # `<head>` is served without them.
  defp document(conn, ctx, tincture, file, base) do
    case Arca.get(Sanctum.Context.actor(ctx), tincture.segments ++ file) do
      {:ok, content} ->
        nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        content = if base, do: inject_head_tags(content, base, nonce), else: content

        conn
        |> put_resp_header("content-security-policy", csp(tincture.manifest, nonce))
        |> send_body("text/html", content)

      {:error, _} ->
        not_found(conn)
    end
  end

  defp read_and_send(conn, ctx, tincture, file, type) do
    case Arca.get(Sanctum.Context.actor(ctx), tincture.segments ++ file) do
      {:ok, content} -> send_body(conn, type, content)
      {:error, _} -> not_found(conn)
    end
  end

  # Text, scripts, JSON and WebAssembly are compressed for a client that
  # accepts it; the response varies on that either way.
  # The body is a tincture version's immutable file, served under its own
  # content type, the derived CSP and the sandbox directive; nothing in it
  # is echoed from the request, so Sobelow's send_resp finding does not
  # apply here.
  # sobelow_skip ["XSS.SendResp"]
  defp send_body(conn, type, content) do
    conn =
      conn
      |> put_resp_header("content-type", content_type(type))
      |> put_resp_header("vary", "accept-encoding")

    if byte_size(content) <= @compress_limit and accepts_gzip?(conn) do
      conn
      |> put_resp_header("content-encoding", "gzip")
      |> send_resp(200, :zlib.gzip(content))
    else
      send_resp(conn, 200, content)
    end
  end

  defp compressible?(type),
    do:
      type in @compressible_types or
        Enum.any?(@compressible_prefixes, &String.starts_with?(type, &1))

  # A textual type names its charset; WebAssembly and binary types do not,
  # since a parameter a browser does not expect can refuse the response.
  defp content_type(type) do
    if String.starts_with?(type, "text/") or
         type in ~w(application/json image/svg+xml model/gltf+json),
       do: type <> "; charset=utf-8",
       else: type
  end

  defp accepts_gzip?(conn) do
    conn
    |> get_req_header("accept-encoding")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.any?(fn coding ->
      case coding |> String.trim() |> String.split(";") do
        ["gzip" | params] -> not Enum.any?(params, &(String.trim(&1) in ["q=0", "q=0.0"]))
        _ -> false
      end
    end)
  end

  # Every miss answers the same JSON refusal, so a reserved file, an unsafe
  # path, a type the rules do not serve and an absent one read alike. The
  # file's headers were set before the read and describe the file, not the
  # refusal: they go, and the JSON body names its own type.
  defp not_found(conn) do
    conn
    |> delete_resp_header("content-type")
    |> delete_resp_header("cache-control")
    |> delete_resp_header("content-encoding")
    |> delete_resp_header("vary")
    |> CyfrWeb.ApiError.send(404, :not_found, nil)
  end

  defp entry_dir(entry) do
    case Path.dirname(entry) do
      "." -> ""
      dir -> dir <> "/"
    end
  end

  # The tags follow the head tag through a function, never a replacement
  # string: a string's `\\` and `\\N` are escapes, and the SDK's source
  # holds backslashes that must reach the page as they are.
  defp inject_head_tags(html, href, nonce) do
    escaped_href = Plug.HTML.html_escape(href)

    injection =
      "\n<base href=\"#{escaped_href}\">\n<script nonce=\"#{nonce}\">#{@sdk_source}</script>"

    Regex.replace(@head_re, html, &(&1 <> injection), global: false)
  end
end
