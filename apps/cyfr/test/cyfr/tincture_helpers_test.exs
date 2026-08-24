# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.TinctureHelpersTest do
  use ExUnit.Case, async: false

  alias Cyfr.TinctureHelpers

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    root = Path.join(System.tmp_dir!(), "tincture_helpers_test_#{:rand.uniform(1_000_000)}")

    # Tinctures are routed via the `components/` Arca prefix. Pointing the
    # storage root (`:base_path`) at a tmp dir gives us an isolated sandbox.
    # Component reads are pinned per athanor, so the fixture files live in
    # the test context's athanor's components subtree.
    prev = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, root)

    ctx = Sanctum.TestContext.local()
    base = Arca.Adapters.Local.build_path(ctx, ["components", ctx.athanor_id])
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
      if prev, do: Application.put_env(:cyfr, :base_path, prev), else: :ok
    end)

    # Asset routing: `["components", athanor_id | rest]` resolves inside the
    # athanor's components subtree. We use an empty rest so files written
    # directly at `base/foo.js` are reachable via
    # `serve_asset(conn, ctx, ["components", athanor_id], ["foo.js"])`.
    %{base: base, ctx: ctx, version_segs: ["components", ctx.athanor_id]}
  end

  defp create_athanor!(kind, slug) do
    {:ok, athanor} =
      Sanctum.Tenancy.Athanors.create(%{
        kind: kind,
        name: slug,
        slug: slug,
        created_by: "test",
        owner_user_id: if(kind == "person", do: "github|https://github.com|#{slug}")
      })

    athanor
  end

  describe "tincture_path/3" do
    test "builds the canonical athanor-scoped shell URL" do
      assert TinctureHelpers.tincture_path("home", "moonmoon", "app") == "/t/home/moonmoon/app"
    end

    test "a person athanor's segment is its @namespace" do
      athanor = create_athanor!("person", "alice")
      segment = TinctureHelpers.athanor_segment(athanor)
      assert segment == "@alice"
      assert TinctureHelpers.tincture_path(segment, "local", "dash") == "/t/@alice/local/dash"
    end

    test "refuses an empty athanor segment" do
      assert_raise FunctionClauseError, fn -> TinctureHelpers.tincture_path("", "local", "x") end
    end
  end

  describe "resolve_athanor/1 and build_public_context/1" do
    test "resolves a group by slug into an unauthenticated context anchored to it" do
      athanor = create_athanor!("group", "acme")

      assert {:ok, %{id: id}} = TinctureHelpers.resolve_athanor("acme")
      assert id == athanor.id
      assert {:ok, ctx} = TinctureHelpers.build_public_context("acme")
      assert %Sanctum.Context{} = ctx
      assert ctx.athanor_id == athanor.id
      assert ctx.scope == :athanor
      assert ctx.authenticated == false
    end

    test "resolves a person by @namespace" do
      athanor = create_athanor!("person", "bob")

      assert {:ok, %{id: id}} = TinctureHelpers.resolve_athanor("@bob")
      assert id == athanor.id
      assert {:ok, ctx} = TinctureHelpers.build_public_context("@bob")
      assert ctx.athanor_id == athanor.id
      # A bare "bob" is a group slug, which nobody created.
      assert {:error, :not_found} = TinctureHelpers.build_public_context("bob")
    end

    test "an unknown segment is not found — never a default athanor" do
      assert {:error, :not_found} = TinctureHelpers.build_public_context("nobody")
      assert {:error, :not_found} = TinctureHelpers.build_public_context("@nobody")
      assert {:error, :not_found} = TinctureHelpers.build_public_context("")
    end

    test "an archived athanor is not found" do
      athanor = create_athanor!("group", "gone")
      {:ok, _} = Sanctum.Tenancy.Athanors.archive(athanor)

      assert {:error, :not_found} = TinctureHelpers.build_public_context("gone")
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
    test "always sets ACAO:* — the opaque-origin iframe consumer needs it",
         %{ctx: ctx, version_segs: vs} do
      conn = Plug.Test.conn(:get, "/t/local/test/app.js")
      result = TinctureHelpers.serve_asset(conn, ctx, vs, ["app.js"])
      assert Plug.Conn.get_resp_header(result, "access-control-allow-origin") == ["*"]
    end
  end
end
