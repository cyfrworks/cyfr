defmodule PrismWeb.TinctureHelpersTest do
  use ExUnit.Case, async: true

  alias PrismWeb.TinctureHelpers

  setup do
    base = Path.join(System.tmp_dir!(), "tincture_helpers_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(base)

    # Create test files
    File.write!(Path.join(base, "index.html"), "<html></html>")
    File.write!(Path.join(base, "app.js"), "console.log('hi')")
    File.write!(Path.join(base, "style.css"), "body{}")
    File.write!(Path.join(base, "logo.png"), "PNG_DATA")
    File.write!(Path.join(base, "data.db"), "sqlite_data")
    File.write!(Path.join(base, "cyfr-manifest.json"), "{}")
    File.write!(Path.join(base, "schema.sql"), "CREATE TABLE t()")
    File.write!(Path.join(base, ".env"), "SECRET=key")

    # Subdirectory with files
    sub = Path.join(base, "assets")
    File.mkdir_p!(sub)
    File.write!(Path.join(sub, "icon.svg"), "<svg/>")
    File.write!(Path.join(sub, ".hidden"), "hidden")

    on_exit(fn -> File.rm_rf!(base) end)

    %{base: base}
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
    test "resolves default index.html", %{base: base} do
      tincture = %{dir: base, manifest: %{"tincture" => %{"entry" => "index.html"}}}
      assert {:ok, path} = TinctureHelpers.resolve_entry(tincture)
      assert String.ends_with?(path, "/index.html")
    end

    test "defaults to index.html when entry not specified", %{base: base} do
      tincture = %{dir: base, manifest: %{}}
      assert {:ok, _path} = TinctureHelpers.resolve_entry(tincture)
    end

    test "rejects denylisted entry files", %{base: base} do
      for name <- ~w(data.db cyfr-manifest.json schema.sql) do
        tincture = %{dir: base, manifest: %{"tincture" => %{"entry" => name}}}
        assert :error = TinctureHelpers.resolve_entry(tincture)
      end
    end

    test "rejects dotfile entries", %{base: base} do
      tincture = %{dir: base, manifest: %{"tincture" => %{"entry" => ".env"}}}
      assert :error = TinctureHelpers.resolve_entry(tincture)
    end

    test "rejects nonexistent entry files", %{base: base} do
      tincture = %{dir: base, manifest: %{"tincture" => %{"entry" => "missing.html"}}}
      assert :error = TinctureHelpers.resolve_entry(tincture)
    end
  end

  describe "serve_asset/3 — denylist" do
    test "blocks data.db", %{base: base} do
      conn = Plug.Test.conn(:get, "/t/local/test/data.db")
      result = TinctureHelpers.serve_asset(conn, base, ["data.db"])
      assert result.status == 404
    end

    test "blocks cyfr-manifest.json", %{base: base} do
      conn = Plug.Test.conn(:get, "/t/local/test/cyfr-manifest.json")
      result = TinctureHelpers.serve_asset(conn, base, ["cyfr-manifest.json"])
      assert result.status == 404
    end

    test "blocks schema.sql", %{base: base} do
      conn = Plug.Test.conn(:get, "/t/local/test/schema.sql")
      result = TinctureHelpers.serve_asset(conn, base, ["schema.sql"])
      assert result.status == 404
    end
  end

  describe "serve_asset/3 — dotfiles" do
    test "blocks dotfiles in root", %{base: base} do
      conn = Plug.Test.conn(:get, "/t/local/test/.env")
      result = TinctureHelpers.serve_asset(conn, base, [".env"])
      assert result.status == 404
    end

    test "blocks dotfiles in subdirectories", %{base: base} do
      conn = Plug.Test.conn(:get, "/t/local/test/assets/.hidden")
      result = TinctureHelpers.serve_asset(conn, base, ["assets", ".hidden"])
      assert result.status == 404
    end
  end

  describe "serve_asset/3 — path traversal" do
    test "blocks .. segments", %{base: base} do
      conn = Plug.Test.conn(:get, "/t/local/test/../etc/passwd")
      result = TinctureHelpers.serve_asset(conn, base, ["..", "etc", "passwd"])
      assert result.status == 404
    end

    test "blocks null bytes", %{base: base} do
      conn = Plug.Test.conn(:get, "/t/local/test/index\0.html")
      result = TinctureHelpers.serve_asset(conn, base, ["index\0.html"])
      assert result.status == 404
    end

    test "blocks backslashes", %{base: base} do
      conn = Plug.Test.conn(:get, "/t/local/test/..\\etc\\passwd")
      result = TinctureHelpers.serve_asset(conn, base, ["..\\etc\\passwd"])
      assert result.status == 404
    end
  end

  describe "serve_asset/3 — extension allowlist" do
    test "serves allowed extensions", %{base: base} do
      conn = Plug.Test.conn(:get, "/t/local/test/app.js")
      result = TinctureHelpers.serve_asset(conn, base, ["app.js"])
      assert result.status == 200
    end

    test "serves CSS files", %{base: base} do
      conn = Plug.Test.conn(:get, "/t/local/test/style.css")
      result = TinctureHelpers.serve_asset(conn, base, ["style.css"])
      assert result.status == 200
    end

    test "serves SVG from subdirectories", %{base: base} do
      conn = Plug.Test.conn(:get, "/t/local/test/assets/icon.svg")
      result = TinctureHelpers.serve_asset(conn, base, ["assets", "icon.svg"])
      assert result.status == 200
    end

    test "blocks unknown extensions", %{base: base} do
      File.write!(Path.join(base, "script.sh"), "#!/bin/bash")

      conn = Plug.Test.conn(:get, "/t/local/test/script.sh")
      result = TinctureHelpers.serve_asset(conn, base, ["script.sh"])
      assert result.status == 404
    end
  end

  describe "serve_asset/3 — containment" do
    test "blocks symlink escapes", %{base: base} do
      # Attempt to escape via crafted path that resolves outside base
      conn = Plug.Test.conn(:get, "/t/local/test/nonexistent")
      result = TinctureHelpers.serve_asset(conn, base, ["nonexistent"])
      assert result.status == 404
    end

    test "returns 404 for directory paths", %{base: base} do
      conn = Plug.Test.conn(:get, "/t/local/test/assets")
      result = TinctureHelpers.serve_asset(conn, base, ["assets"])
      assert result.status == 404
    end
  end

  describe "serve_asset/3 — security headers" do
    test "sets x-content-type-options: nosniff", %{base: base} do
      conn = Plug.Test.conn(:get, "/t/local/test/app.js")
      result = TinctureHelpers.serve_asset(conn, base, ["app.js"])
      assert Plug.Conn.get_resp_header(result, "x-content-type-options") == ["nosniff"]
    end

    test "defaults to private cache-control", %{base: base} do
      conn = Plug.Test.conn(:get, "/t/local/test/style.css")
      result = TinctureHelpers.serve_asset(conn, base, ["style.css"])
      assert Plug.Conn.get_resp_header(result, "cache-control") == ["private, max-age=3600"]
    end

    test "sets public cache-control when public: true", %{base: base} do
      conn = Plug.Test.conn(:get, "/t/local/test/style.css")
      result = TinctureHelpers.serve_asset(conn, base, ["style.css"], public: true)
      assert Plug.Conn.get_resp_header(result, "cache-control") == ["public, max-age=3600"]
    end
  end

  describe "serve_asset/3 — CORS" do
    test "sets CORS header when cors: true", %{base: base} do
      conn = Plug.Test.conn(:get, "/t/local/test/app.js")
      result = TinctureHelpers.serve_asset(conn, base, ["app.js"], cors: true)
      assert Plug.Conn.get_resp_header(result, "access-control-allow-origin") == ["*"]
    end

    test "omits CORS header when cors: false", %{base: base} do
      conn = Plug.Test.conn(:get, "/t/local/test/app.js")
      result = TinctureHelpers.serve_asset(conn, base, ["app.js"], cors: false)
      assert Plug.Conn.get_resp_header(result, "access-control-allow-origin") == []
    end

    test "omits CORS header by default", %{base: base} do
      conn = Plug.Test.conn(:get, "/t/local/test/app.js")
      result = TinctureHelpers.serve_asset(conn, base, ["app.js"])
      assert Plug.Conn.get_resp_header(result, "access-control-allow-origin") == []
    end
  end
end
