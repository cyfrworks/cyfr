defmodule Cyfr.TinctureHelpersTest do
  use ExUnit.Case, async: false

  alias Cyfr.TinctureHelpers
  alias Sanctum.Context

  setup do
    base = Path.join(System.tmp_dir!(), "tincture_helpers_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(base)

    # Tinctures are routed via the `components/` Arca prefix, which the Local
    # adapter resolves against `:components_path`. Pointing it at a tmp dir
    # gives us an isolated sandbox.
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

    prev = Application.get_env(:cyfr, :components_path)
    Application.put_env(:cyfr, :components_path, base)

    on_exit(fn ->
      File.rm_rf!(base)
      if prev, do: Application.put_env(:cyfr, :components_path, prev), else: :ok
    end)

    # Asset routing: `["components" | rest]` resolves to `components_path ++ rest`.
    # We use an empty rest so files written directly at `base/foo.js` are reachable
    # via `serve_asset(conn, ctx, ["components"], ["foo.js"])`.
    %{base: base, ctx: Sanctum.TestContext.local(), version_segs: ["components"]}
  end

  describe "entry_url/3" do
    test "builds canonical versionless shell URL (entry filename excluded)" do
      assert TinctureHelpers.entry_url("local", "dash", "index.html") ==
               "/t/local/dash"
    end

    test "entry filename is ignored — always returns index route" do
      assert TinctureHelpers.entry_url("moonmoon", "app", "main.html") ==
               "/t/moonmoon/app"
    end
  end

  describe "build_public_context/0" do
    test "returns unauthenticated context with empty org_id in Core mode" do
      ctx = TinctureHelpers.build_public_context()
      assert %Sanctum.Context{} = ctx
      assert ctx.org_id == ""
      assert ctx.authenticated == false
    end
  end

  describe "resolve_entry/1" do
    test "returns the manifest's tincture.entry when valid" do
      tincture = %{manifest: %{"tincture" => %{"entry" => "index.html"}}}
      assert {:ok, "index.html"} = TinctureHelpers.resolve_entry(tincture)
    end

    test "defaults to index.html when entry not specified" do
      tincture = %{manifest: %{}}
      assert {:ok, "index.html"} = TinctureHelpers.resolve_entry(tincture)
    end

    test "rejects denylisted entry files" do
      for name <- ~w(data.db cyfr-manifest.json schema.sql) do
        tincture = %{manifest: %{"tincture" => %{"entry" => name}}}
        assert :error = TinctureHelpers.resolve_entry(tincture)
      end
    end

    test "rejects dotfile entries" do
      tincture = %{manifest: %{"tincture" => %{"entry" => ".env"}}}
      assert :error = TinctureHelpers.resolve_entry(tincture)
    end

    test "rejects entries with traversal" do
      tincture = %{manifest: %{"tincture" => %{"entry" => "../escape.html"}}}
      assert :error = TinctureHelpers.resolve_entry(tincture)
    end

    test "rejects absolute-path entries" do
      tincture = %{manifest: %{"tincture" => %{"entry" => "/etc/passwd"}}}
      assert :error = TinctureHelpers.resolve_entry(tincture)
    end
  end

  describe "serve_asset/5 — denylist" do
    test "blocks data.db", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/data.db")
      result = TinctureHelpers.serve_asset(conn, ctx, vs, ["data.db"])
      assert result.status == 404
    end

    test "blocks cyfr-manifest.json", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/cyfr-manifest.json")
      result = TinctureHelpers.serve_asset(conn, ctx, vs, ["cyfr-manifest.json"])
      assert result.status == 404
    end

    test "blocks schema.sql", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/schema.sql")
      result = TinctureHelpers.serve_asset(conn, ctx, vs, ["schema.sql"])
      assert result.status == 404
    end
  end

  describe "serve_asset/5 — dotfiles" do
    test "blocks dotfiles in root", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/.env")
      result = TinctureHelpers.serve_asset(conn, ctx, vs, [".env"])
      assert result.status == 404
    end

    test "blocks dotfiles in subdirectories", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/assets/.hidden")
      result = TinctureHelpers.serve_asset(conn, ctx, vs, ["assets", ".hidden"])
      assert result.status == 404
    end
  end

  describe "serve_asset/5 — path traversal" do
    test "blocks .. segments", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/../etc/passwd")
      result = TinctureHelpers.serve_asset(conn, ctx, vs, ["..", "etc", "passwd"])
      assert result.status == 404
    end

    test "blocks null bytes", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/index\0.html")
      result = TinctureHelpers.serve_asset(conn, ctx, vs, ["index\0.html"])
      assert result.status == 404
    end

    test "blocks backslashes", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/..\\etc\\passwd")
      result = TinctureHelpers.serve_asset(conn, ctx, vs, ["..\\etc\\passwd"])
      assert result.status == 404
    end
  end

  describe "serve_asset/5 — extension allowlist" do
    test "serves allowed extensions", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/app.js")
      result = TinctureHelpers.serve_asset(conn, ctx, vs, ["app.js"])
      assert result.status == 200
    end

    test "serves CSS files", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/style.css")
      result = TinctureHelpers.serve_asset(conn, ctx, vs, ["style.css"])
      assert result.status == 200
    end

    test "serves SVG from subdirectories", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/assets/icon.svg")
      result = TinctureHelpers.serve_asset(conn, ctx, vs, ["assets", "icon.svg"])
      assert result.status == 200
    end

    test "blocks unknown extensions", %{ctx: ctx, version_segs: vs, base: base} do
      File.write!(Path.join(base, "script.sh"), "#!/bin/bash")

      conn = Plug.Test.conn(:get, "/t/local/test/script.sh")
      result = TinctureHelpers.serve_asset(conn, ctx, vs, ["script.sh"])
      assert result.status == 404
    end
  end

  describe "serve_asset/5 — containment" do
    test "returns 404 for nonexistent files", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/missing.js")
      result = TinctureHelpers.serve_asset(conn, ctx, vs, ["missing.js"])
      assert result.status == 404
    end

    test "returns 404 for directory paths", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/assets")
      # Directory paths fall back to extension check (no extension → 404)
      result = TinctureHelpers.serve_asset(conn, ctx, vs, ["assets"])
      assert result.status == 404
    end
  end

  describe "serve_asset/5 — security headers" do
    test "sets x-content-type-options: nosniff", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/app.js")
      result = TinctureHelpers.serve_asset(conn, ctx, vs, ["app.js"])
      assert Plug.Conn.get_resp_header(result, "x-content-type-options") == ["nosniff"]
    end

    test "defaults to private cache-control", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/style.css")
      result = TinctureHelpers.serve_asset(conn, ctx, vs, ["style.css"])
      assert Plug.Conn.get_resp_header(result, "cache-control") == ["private, max-age=3600"]
    end

    test "sets public cache-control when public: true", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/style.css")
      result = TinctureHelpers.serve_asset(conn, ctx, vs, ["style.css"], public: true)
      assert Plug.Conn.get_resp_header(result, "cache-control") == ["public, max-age=3600"]
    end
  end

  describe "serve_asset/5 — CORS" do
    test "sets CORS header when cors: true", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/app.js")
      result = TinctureHelpers.serve_asset(conn, ctx, vs, ["app.js"], cors: true)
      assert Plug.Conn.get_resp_header(result, "access-control-allow-origin") == ["*"]
    end

    test "omits CORS header when cors: false", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/app.js")
      result = TinctureHelpers.serve_asset(conn, ctx, vs, ["app.js"], cors: false)
      assert Plug.Conn.get_resp_header(result, "access-control-allow-origin") == []
    end

    test "omits CORS header by default", %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/app.js")
      result = TinctureHelpers.serve_asset(conn, ctx, vs, ["app.js"])
      assert Plug.Conn.get_resp_header(result, "access-control-allow-origin") == []
    end
  end
end
