# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Ingress.TinctureAssetsTest do
  @moduledoc """
  Tincture bytes over HTTP: an asset is served only when its path is safe,
  unreserved and of an allowed extension, with the same headers on every
  adapter; the entry page is served with one nonce in its CSP and its
  inline SDK, a `<base>` for the entry's own directory, the SDK injected
  once into the first `<head>`, and a page without a head left as it is.
  """

  use ExUnit.Case, async: false

  alias CyfrWeb.Ingress.TinctureAssets

  @sdk File.read!(Path.join(:code.priv_dir(:cyfr), "static/sdk/cyfr.js"))

  @csp "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; " <>
         "connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'self'"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    root =
      Path.join(System.tmp_dir!(), "tincture_assets_test_#{System.unique_integer([:positive])}")

    # Tinctures are routed via the `components/` Arca prefix. Pointing the
    # storage root (`:base_path`) at a tmp dir gives us an isolated sandbox.
    # Component reads are pinned per athanor, so the fixture files live in
    # the test context's athanor's components subtree.
    prev = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, root)

    ctx = Sanctum.TestContext.local()
    base = Arca.Adapters.Local.build_path(Sanctum.Context.actor(ctx), ["components"])
    File.mkdir_p!(base)
    File.write!(Path.join(base, "index.html"), "<html></html>")
    File.write!(Path.join(base, "app.js"), "console.log('hi')")
    File.write!(Path.join(base, "style.css"), "body{}")
    File.write!(Path.join(base, "logo.png"), "PNG_DATA")
    File.write!(Path.join(base, "data.db"), "sqlite_data")
    File.write!(Path.join(base, "cyfr-manifest.json"), "{}")
    File.write!(Path.join(base, "schema.sql"), "CREATE TABLE t()")
    File.write!(Path.join(base, ".env"), "SECRET=key")

    sub = Path.join(base, "assets")
    File.mkdir_p!(sub)
    File.write!(Path.join(sub, "icon.svg"), "<svg/>")
    File.write!(Path.join(sub, ".hidden"), "hidden")

    on_exit(fn ->
      File.rm_rf!(root)
      if prev, do: Application.put_env(:arca, :base_path, prev), else: :ok
    end)

    # Asset routing: `["components" | rest]` resolves inside the context's
    # athanor's components subtree. We use an empty rest so files written
    # directly at `base/foo.js` are reachable via
    # `serve_asset(conn, ctx, ["components"], ["foo.js"])`.
    %{base: base, ctx: ctx, version_segs: ["components"]}
  end

  describe "the tincture URL the adapter is served under" do
    test "is the canonical athanor-scoped path" do
      assert Prima.TinctureUrl.path("home", "moonmoon", "app") == "/t/home/moonmoon/app"
    end

    test "a person athanor's segment is its @namespace" do
      {:ok, athanor} =
        Sanctum.Tenancy.Athanors.create(%{
          kind: "person",
          name: "alice",
          slug: "alice",
          created_by: "test",
          owner_user_id: "github|https://github.com|alice"
        })

      segment = Sanctum.Tenancy.Athanors.route_slug(athanor)
      assert segment == "@alice"
      assert Prima.TinctureUrl.path(segment, "local", "dash") == "/t/@alice/local/dash"
    end

    test "refuses an empty athanor segment" do
      assert_raise FunctionClauseError, fn -> Prima.TinctureUrl.path("", "local", "x") end
    end
  end

  describe "serve_asset/5 — denylist" do
    test "blocks data.db", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/data.db")
      result = TinctureAssets.serve_asset(conn, ctx, vs, ["data.db"])
      assert result.status == 404
    end

    test "blocks cyfr-manifest.json", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/cyfr-manifest.json")
      result = TinctureAssets.serve_asset(conn, ctx, vs, ["cyfr-manifest.json"])
      assert result.status == 404
    end

    test "blocks schema.sql", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/schema.sql")
      result = TinctureAssets.serve_asset(conn, ctx, vs, ["schema.sql"])
      assert result.status == 404
    end
  end

  describe "serve_asset/5 — dotfiles" do
    test "blocks dotfiles in root", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/.env")
      result = TinctureAssets.serve_asset(conn, ctx, vs, [".env"])
      assert result.status == 404
    end

    test "blocks dotfiles in subdirectories", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/assets/.hidden")
      result = TinctureAssets.serve_asset(conn, ctx, vs, ["assets", ".hidden"])
      assert result.status == 404
    end
  end

  describe "serve_asset/5 — path traversal" do
    test "blocks .. segments", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/../etc/passwd")
      result = TinctureAssets.serve_asset(conn, ctx, vs, ["..", "etc", "passwd"])
      assert result.status == 404
    end

    test "blocks null bytes", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/index\0.html")
      result = TinctureAssets.serve_asset(conn, ctx, vs, ["index\0.html"])
      assert result.status == 404
    end

    test "blocks backslashes", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/..\\etc\\passwd")
      result = TinctureAssets.serve_asset(conn, ctx, vs, ["..\\etc\\passwd"])
      assert result.status == 404
    end
  end

  describe "serve_asset/5 — extension allowlist" do
    test "serves allowed extensions", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/app.js")
      result = TinctureAssets.serve_asset(conn, ctx, vs, ["app.js"])
      assert result.status == 200
    end

    test "serves CSS files", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/style.css")
      result = TinctureAssets.serve_asset(conn, ctx, vs, ["style.css"])
      assert result.status == 200
    end

    test "serves SVG from subdirectories", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/assets/icon.svg")
      result = TinctureAssets.serve_asset(conn, ctx, vs, ["assets", "icon.svg"])
      assert result.status == 200
    end

    test "blocks unknown extensions", %{ctx: ctx, version_segs: vs, base: base} do
      File.write!(Path.join(base, "script.sh"), "#!/bin/bash")

      conn = Plug.Test.conn(:get, "/t/local/test/script.sh")
      result = TinctureAssets.serve_asset(conn, ctx, vs, ["script.sh"])
      assert result.status == 404
    end
  end

  describe "serve_asset/5 — containment" do
    test "returns 404 for nonexistent files", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/missing.js")
      result = TinctureAssets.serve_asset(conn, ctx, vs, ["missing.js"])
      assert result.status == 404
    end

    test "returns 404 for directory paths", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/assets")
      # Directory paths fall back to extension check (no extension → 404)
      result = TinctureAssets.serve_asset(conn, ctx, vs, ["assets"])
      assert result.status == 404
    end
  end

  describe "serve_asset/5 — security headers" do
    test "sets x-content-type-options: nosniff", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/app.js")
      result = TinctureAssets.serve_asset(conn, ctx, vs, ["app.js"])
      assert Plug.Conn.get_resp_header(result, "x-content-type-options") == ["nosniff"]
    end

    test "defaults to private cache-control", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/style.css")
      result = TinctureAssets.serve_asset(conn, ctx, vs, ["style.css"])
      assert Plug.Conn.get_resp_header(result, "cache-control") == ["private, max-age=3600"]
    end

    test "sets public cache-control when public: true", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/style.css")
      result = TinctureAssets.serve_asset(conn, ctx, vs, ["style.css"], public: true)
      assert Plug.Conn.get_resp_header(result, "cache-control") == ["public, max-age=3600"]
    end
  end

  describe "serve_asset/5 — CORS" do
    test "always sets ACAO:* — the opaque-origin iframe consumer needs it",
         %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/app.js")
      result = TinctureAssets.serve_asset(conn, ctx, vs, ["app.js"])
      assert Plug.Conn.get_resp_header(result, "access-control-allow-origin") == ["*"]
    end
  end

  defp page!(base, rel, html) do
    path = Path.join(base, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, html)
  end

  defp serve_index(ctx, vs, entry, base_href) do
    conn = Plug.Test.conn(:get, "/t/home/local/app")
    TinctureAssets.serve_index(conn, ctx, vs, entry, base_href, @csp)
  end

  defp csp_nonce(conn) do
    [csp] = Plug.Conn.get_resp_header(conn, "content-security-policy")
    [_, nonce] = Regex.run(~r/script-src 'self' 'nonce-([A-Za-z0-9_-]+)'/, csp)
    nonce
  end

  describe "serve_index/6" do
    test "the CSP's nonce is the inline SDK's, fresh for every request",
         %{ctx: ctx, version_segs: vs, base: base} do
      page!(base, "index.html", "<html><head><title>t</title></head><body></body></html>")

      first = serve_index(ctx, vs, "index.html", "/t/home/local/app/")
      second = serve_index(ctx, vs, "index.html", "/t/home/local/app/")

      assert first.status == 200
      nonce = csp_nonce(first)
      assert byte_size(Base.url_decode64!(nonce, padding: false)) == 16
      assert first.resp_body =~ ~s(<script nonce="#{nonce}">)
      assert [_one] = Regex.scan(~r/<script nonce="/, first.resp_body)

      # The rest of the policy is the caller's, untouched.
      [csp] = Plug.Conn.get_resp_header(first, "content-security-policy")

      assert csp ==
               String.replace(@csp, "script-src 'self'", "script-src 'self' 'nonce-#{nonce}'")

      refute csp_nonce(second) == nonce
    end

    test "the embedded SDK is served whole, once, into the first head",
         %{ctx: ctx, version_segs: vs, base: base} do
      assert byte_size(@sdk) > 1_000, "the SDK at priv/static/sdk/cyfr.js is missing or empty"
      assert @sdk =~ "window.cyfr"

      page!(base, "two-heads.html", "<html><head></head><body><head></head></body></html>")
      conn = serve_index(ctx, vs, "two-heads.html", "/t/home/local/app/")

      assert conn.status == 200
      assert [_once] = :binary.matches(conn.resp_body, @sdk)

      # The injection follows the first head tag and nothing else moves.
      [before_sdk, after_sdk] = String.split(conn.resp_body, @sdk)
      assert String.starts_with?(before_sdk, "<html><head>\n<base href=")
      assert String.ends_with?(after_sdk, "</script></head><body><head></head></body></html>")
    end

    test "a head with attributes is injected after its opening tag",
         %{ctx: ctx, version_segs: vs, base: base} do
      page!(base, "attrs.html", ~s(<html><head lang="en"><meta charset="utf-8"></head></html>))
      conn = serve_index(ctx, vs, "attrs.html", "/t/home/local/app/")

      assert conn.resp_body =~
               ~r{\A<html><head lang="en">\n<base href="/t/home/local/app/">\n<script nonce=}
    end

    test "the base names the entry's own directory, escaped",
         %{ctx: ctx, version_segs: vs, base: base} do
      page!(base, "dist/index.html", "<html><head></head><body>Built</body></html>")

      built = serve_index(ctx, vs, "dist/index.html", "/t/home/local/app/")
      assert built.resp_body =~ ~s(<base href="/t/home/local/app/dist/">)

      # A base href that carries markup is escaped, never spliced raw.
      hostile = serve_index(ctx, vs, "dist/index.html", ~s[/t/x"><script>alert(1)</script>/])

      assert hostile.resp_body =~
               ~s[<base href="/t/x&quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt;/dist/">]

      refute hostile.resp_body =~ "<script>alert(1)</script>"
    end

    test "a page with no head is served unchanged, SDK and all left out",
         %{ctx: ctx, version_segs: vs, base: base} do
      html = "<html><body>no head here</body></html>"
      page!(base, "bare.html", html)

      conn = serve_index(ctx, vs, "bare.html", "/t/home/local/app/")

      assert conn.status == 200
      assert conn.resp_body == html
    end

    test "the page is text/html with one charset and nosniff",
         %{ctx: ctx, version_segs: vs, base: base} do
      page!(base, "index.html", "<html><head></head></html>")
      conn = serve_index(ctx, vs, "index.html", "/t/home/local/app/")

      assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
      assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "an entry the store does not hold is a 404", %{ctx: ctx, version_segs: vs} do
      conn = serve_index(ctx, vs, "missing.html", "/t/home/local/app/")
      assert conn.status == 404
      assert conn.resp_body == "Not Found"
    end
  end

  describe "serve_asset/5 — the rules it serves by" do
    test "the reserved files and extensions are the component domain's",
         %{ctx: ctx, version_segs: vs} do
      rules = Compendium.tincture_asset_rules()

      for reserved <- rules.reserved_files do
        conn = Plug.Test.conn(:get, "/t/local/test/" <> reserved)
        assert TinctureAssets.serve_asset(conn, ctx, vs, [reserved]).status == 404
      end

      assert ".js" in rules.allowed_extensions
      refute ".sh" in rules.allowed_extensions
    end
  end
end
