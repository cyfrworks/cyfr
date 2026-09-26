# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Ingress.TinctureAssetsTest do
  @moduledoc """
  Tincture bytes over HTTP: a file is served only when its path is safe,
  unreserved and of a served type, with the same headers on every response
  — `Referrer-Policy: no-referrer`, the route's cache lifetime, the
  wildcard CORS answer an opaque-origin frame needs — and compressed when
  it is text, a script or WebAssembly and the client accepts it. Every
  document carries the policy the frame's rules derive from its version's
  declaration, with a fresh nonce and a `sandbox` directive; the entry page
  also its inline SDK, a `<base>` for the entry's own directory, injected
  once into the first `<head>`, and a page without a head left as it is.
  """

  use ExUnit.Case, async: false

  alias CyfrWeb.Ingress.TinctureAssets

  @sdk File.read!(Path.join(:code.priv_dir(:cyfr), "static/sdk/cyfr.js"))

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

    # The version's files sit at the athanor's `components/` root, so the
    # tincture row names that as its segments.
    %{base: base, ctx: ctx, tincture: %{segments: ["components"], manifest: %{}}}
  end

  defp serve(ctx, tincture, file, opts \\ []) do
    conn =
      Enum.reduce(Keyword.get(opts, :headers, []), Plug.Test.conn(:get, "/_s/x"), fn {k, v},
                                                                                     conn ->
        Plug.Conn.put_req_header(conn, k, v)
      end)

    TinctureAssets.serve(conn, ctx, tincture, file,
      cache: Keyword.get(opts, :cache, {:private, 600}),
      base: Keyword.get(opts, :base, "/_s/cred/local/app/1.0.0/")
    )
  end

  defp header(conn, name), do: Plug.Conn.get_resp_header(conn, name)

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

  describe "what is never served" do
    test "the reserved files, each the component domain's", %{ctx: ctx, tincture: t} do
      for reserved <- Compendium.tincture_asset_rules().reserved_files do
        assert_not_found(serve(ctx, t, [reserved]))
      end
    end

    test "dotfiles, at the root and below", %{ctx: ctx, tincture: t} do
      assert_not_found(serve(ctx, t, [".env"]))
      assert_not_found(serve(ctx, t, ["assets", ".hidden"]))
    end

    test "a path that leaves the version", %{ctx: ctx, tincture: t} do
      assert_not_found(serve(ctx, t, ["..", "etc", "passwd"]))
      assert_not_found(serve(ctx, t, ["index\0.html"]))
      assert_not_found(serve(ctx, t, ["..\\etc\\passwd"]))
      assert_not_found(serve(ctx, t, []))
    end

    test "a type the frame's rules do not serve", %{ctx: ctx, tincture: t, base: base} do
      File.write!(Path.join(base, "script.sh"), "#!/bin/bash")
      File.write!(Path.join(base, "picture.webp"), "RIFF")

      assert_not_found(serve(ctx, t, ["script.sh"]))
      assert_not_found(serve(ctx, t, ["picture.webp"]))
      refute Map.has_key?(Compendium.tincture_served_types(), ".sh")
    end

    test "a file the store does not hold, or a directory", %{ctx: ctx, tincture: t} do
      missing = serve(ctx, t, ["missing.js"])
      assert_not_found(missing)
      # The file's type, lifetime and encoding were set before the read
      # found nothing; the refusal carries none of them.
      assert header(missing, "cache-control") == []
      assert header(missing, "content-encoding") == []

      assert_not_found(serve(ctx, t, ["assets"]))
    end
  end

  describe "every response" do
    test "is served with its type from the frame's rules", %{ctx: ctx, tincture: t, base: base} do
      File.write!(Path.join(base, "engine.wasm"), <<0, 97, 115, 109, 1, 0, 0, 0>>)

      assert serve(ctx, t, ["app.js"]).status == 200

      assert header(serve(ctx, t, ["app.js"]), "content-type") == [
               "text/javascript; charset=utf-8"
             ]

      assert header(serve(ctx, t, ["style.css"]), "content-type") == ["text/css; charset=utf-8"]

      assert header(serve(ctx, t, ["assets", "icon.svg"]), "content-type") == [
               "image/svg+xml; charset=utf-8"
             ]

      # WebAssembly and binaries carry their bare type: a parameter a
      # browser does not expect can refuse the response.
      assert header(serve(ctx, t, ["engine.wasm"]), "content-type") == ["application/wasm"]
      assert header(serve(ctx, t, ["logo.png"]), "content-type") == ["image/png"]
    end

    test "carries no referrer, nosniff, the wildcard CORS answer and same-origin framing",
         %{ctx: ctx, tincture: t} do
      for file <- [["app.js"], ["logo.png"], ["index.html"]] do
        conn = serve(ctx, t, file)
        assert header(conn, "referrer-policy") == ["no-referrer"], inspect(file)
        assert header(conn, "x-content-type-options") == ["nosniff"]
        assert header(conn, "access-control-allow-origin") == ["*"]
        assert header(conn, "x-frame-options") == ["SAMEORIGIN"]
      end
    end

    test "is cached as the route says, a private one for no longer than it names",
         %{ctx: ctx, tincture: t} do
      assert header(serve(ctx, t, ["style.css"], cache: {:private, 42}), "cache-control") ==
               ["private, max-age=42"]

      assert header(serve(ctx, t, ["style.css"], cache: {:public, 3600}), "cache-control") ==
               ["public, max-age=3600"]

      assert header(serve(ctx, t, ["index.html"], cache: :revalidate), "cache-control") ==
               ["no-cache"]
    end
  end

  describe "compression" do
    test "text, scripts and WebAssembly are gzipped for a client that accepts it",
         %{ctx: ctx, tincture: t, base: base} do
      wasm = <<0, 97, 115, 109, 1, 0, 0, 0>> <> :binary.copy(<<0>>, 4096)
      File.write!(Path.join(base, "engine.wasm"), wasm)

      for {file, bytes} <- [
            {["app.js"], "console.log('hi')"},
            {["style.css"], "body{}"},
            {["engine.wasm"], wasm}
          ] do
        conn = serve(ctx, t, file, headers: [{"accept-encoding", "br, gzip;q=0.8"}])
        assert conn.status == 200
        assert header(conn, "content-encoding") == ["gzip"], inspect(file)
        assert header(conn, "vary") == ["accept-encoding"]
        assert :zlib.gunzip(conn.resp_body) == bytes
      end
    end

    test "a client that does not accept gzip gets the bytes as stored",
         %{ctx: ctx, tincture: t} do
      for headers <- [[], [{"accept-encoding", "br"}], [{"accept-encoding", "gzip;q=0"}]] do
        conn = serve(ctx, t, ["app.js"], headers: headers)
        assert header(conn, "content-encoding") == []
        assert header(conn, "vary") == ["accept-encoding"]
        assert conn.resp_body == "console.log('hi')"
      end
    end

    test "images are sent as stored", %{ctx: ctx, tincture: t} do
      conn = serve(ctx, t, ["logo.png"], headers: [{"accept-encoding", "gzip"}])
      assert conn.status == 200
      assert header(conn, "content-encoding") == []
    end
  end

  defp page!(base, rel, html) do
    path = Path.join(base, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, html)
  end

  defp csp(conn) do
    [csp] = header(conn, "content-security-policy")
    csp
  end

  defp csp_nonce(conn) do
    [_, nonce] = Regex.run(~r/script-src 'self' 'nonce-([A-Za-z0-9_-]+)'/, csp(conn))
    nonce
  end

  defp endpoint_origin do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(Sanctum.origin())

    if port == URI.default_port(scheme),
      do: "#{scheme}://#{host}",
      else: "#{scheme}://#{host}:#{port}"
  end

  describe "a document's policy" do
    test "is the frame's rules' derivation from the declaration, with a sandbox of what it declares",
         %{ctx: ctx, base: base} do
      page!(base, "index.html", "<html><head></head><body></body></html>")

      manifest = %{
        "tincture" => %{
          "connect" => ["api.example.com", "evil.com\n", "https://x.com"],
          "frame" => %{"capabilities" => ["pointer_lock", "fullscreen"]}
        }
      }

      conn = serve(ctx, %{segments: ["components"], manifest: manifest}, ["index.html"])
      nonce = csp_nonce(conn)

      {:ok, sandbox} = Compendium.tincture_sandbox_tokens(["pointer_lock", "fullscreen"])

      assert csp(conn) ==
               Compendium.tincture_csp(manifest, %{endpoint: endpoint_origin(), nonce: nonce}) <>
                 "; sandbox " <> Enum.join(sandbox, " ")

      assert csp(conn) == TinctureAssets.csp(manifest, nonce)

      # Every directive is one the rules derive or the sandbox; none names
      # a connect entry the grammar refuses, and the sandbox opens scripts
      # and pointer lock, never the origin, navigation, popups or forms.
      directives = csp(conn) |> String.split("; ") |> Enum.map(&hd(String.split(&1, " ")))

      assert directives ==
               ~w(default-src script-src worker-src style-src img-src font-src media-src
                  connect-src object-src base-uri frame-ancestors form-action sandbox)

      assert csp(conn) =~ "connect-src #{endpoint_origin()} https://api.example.com;"
      refute csp(conn) =~ "evil.com"
      refute csp(conn) =~ "x.com;"
      assert csp(conn) =~ "; sandbox allow-scripts allow-pointer-lock"

      for token <- Compendium.Tincture.Rules.forbidden_sandbox_tokens(),
          do: refute(csp(conn) =~ token)
    end

    test "a declaration the rules refuse opens scripts alone", %{ctx: ctx, base: base} do
      page!(base, "index.html", "<html><head></head></html>")
      manifest = %{"tincture" => %{"frame" => %{"capabilities" => ["camera"]}}}

      conn = serve(ctx, %{segments: ["components"], manifest: manifest}, ["index.html"])
      assert String.ends_with?(csp(conn), "; sandbox allow-scripts")
    end

    test "another page of the version carries the same policy and no SDK",
         %{ctx: ctx, tincture: t, base: base} do
      page!(base, "page2.html", "<html><head></head><body>two</body></html>")
      conn = serve(ctx, t, ["page2.html"])

      assert conn.status == 200
      assert csp(conn) == TinctureAssets.csp(%{}, csp_nonce(conn))
      assert csp(conn) =~ "; sandbox allow-scripts"
      assert conn.resp_body == "<html><head></head><body>two</body></html>"
    end

    test "a non-document keeps the pipeline's locked-down header", %{ctx: ctx, tincture: t} do
      assert header(serve(ctx, t, ["app.js"]), "content-security-policy") == []
    end
  end

  describe "the entry page" do
    test "the policy's nonce is the inline SDK's, fresh for every request",
         %{ctx: ctx, tincture: t, base: base} do
      page!(base, "index.html", "<html><head><title>t</title></head><body></body></html>")

      first = serve(ctx, t, ["index.html"])
      second = serve(ctx, t, ["index.html"])

      assert first.status == 200
      nonce = csp_nonce(first)
      assert byte_size(Base.url_decode64!(nonce, padding: false)) == 16
      assert first.resp_body =~ ~s(<script nonce="#{nonce}">)
      assert [_one] = Regex.scan(~r/<script nonce="/, first.resp_body)
      refute csp_nonce(second) == nonce
    end

    test "the embedded SDK is served whole, once, into the first head",
         %{ctx: ctx, base: base} do
      assert byte_size(@sdk) > 1_000, "the SDK at priv/static/sdk/cyfr.js is missing or empty"
      assert @sdk =~ "window.cyfr"

      page!(base, "two-heads.html", "<html><head></head><body><head></head></body></html>")
      t = %{segments: ["components"], manifest: %{"tincture" => %{"entry" => "two-heads.html"}}}
      conn = serve(ctx, t, ["two-heads.html"])

      assert conn.status == 200
      assert [_once] = :binary.matches(conn.resp_body, @sdk)

      # The injection follows the first head tag and nothing else moves.
      [before_sdk, after_sdk] = String.split(conn.resp_body, @sdk)
      assert String.starts_with?(before_sdk, "<html><head>\n<base href=")
      assert String.ends_with?(after_sdk, "</script></head><body><head></head></body></html>")
    end

    test "a head with attributes is injected after its opening tag",
         %{ctx: ctx, tincture: t, base: base} do
      page!(base, "index.html", ~s(<html><head lang="en"><meta charset="utf-8"></head></html>))
      conn = serve(ctx, t, ["index.html"], base: "/t/home/local/app/")

      assert conn.resp_body =~
               ~r{\A<html><head lang="en">\n<base href="/t/home/local/app/">\n<script nonce=}
    end

    test "the base names the entry's own directory, escaped", %{ctx: ctx, base: base} do
      page!(base, "dist/index.html", "<html><head></head><body>Built</body></html>")
      t = %{segments: ["components"], manifest: %{"tincture" => %{"entry" => "dist/index.html"}}}

      built = serve(ctx, t, ["dist", "index.html"], base: "/_s/cred/local/app/1.0.0/")
      assert built.resp_body =~ ~s(<base href="/_s/cred/local/app/1.0.0/dist/">)

      # A base that carries markup is escaped, never spliced raw.
      hostile = serve(ctx, t, ["dist", "index.html"], base: ~s[/t/x"><script>alert(1)</script>/])

      assert hostile.resp_body =~
               ~s[<base href="/t/x&quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt;/dist/">]

      refute hostile.resp_body =~ "<script>alert(1)</script>"
    end

    test "a page with no head is served unchanged, SDK and all left out",
         %{ctx: ctx, tincture: t, base: base} do
      html = "<html><body>no head here</body></html>"
      page!(base, "index.html", html)

      conn = serve(ctx, t, ["index.html"])

      assert conn.status == 200
      assert conn.resp_body == html
    end

    test "the page is text/html with one charset, compressed when accepted",
         %{ctx: ctx, tincture: t, base: base} do
      page!(base, "index.html", "<html><head></head></html>")
      conn = serve(ctx, t, ["index.html"], headers: [{"accept-encoding", "gzip"}])

      assert header(conn, "content-type") == ["text/html; charset=utf-8"]
      assert header(conn, "content-encoding") == ["gzip"]
      assert :zlib.gunzip(conn.resp_body) =~ "<script nonce="
    end

    test "an entry the store does not hold is a 404", %{ctx: ctx} do
      t = %{segments: ["components"], manifest: %{"tincture" => %{"entry" => "missing.html"}}}
      assert_not_found(serve(ctx, t, ["missing.html"]))
    end
  end

  # Every miss is the JSON `not_found` refusal `CyfrWeb.ApiError` renders,
  # never a plain-text body.
  defp assert_not_found(conn) do
    assert conn.status == 404
    assert ["application/json" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
    assert %{"code" => "not_found", "message" => "Not found"} = Jason.decode!(conn.resp_body)
  end
end
