# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.TinctureControllerTest do
  use CyfrWeb.ConnCase, async: false

  import Prima.Test.Wait

  # A version's artifact digest, and its release digest (its bytes bound to
  # its manifest, `Compendium.ReleaseDigest`) as the registry records them:
  # the release digest is what an asset credential names.
  defp digest(name), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, name), case: :lower)
  defp release_digest(name), do: digest("release:" <> name)

  defp tincture_dir(name) do
    Arca.Adapters.Local.build_path(
      Sanctum.Context.actor(Sanctum.TestContext.local()),
      ["components", "tinctures", "local", name, "1.0.0"]
    )
  end

  setup do
    base = Path.join(System.tmp_dir!(), "tincture_ctrl_#{:rand.uniform(1_000_000)}")
    original = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    # ── Private tincture (auth-dash) ─────────────────────────────────
    private_dir = tincture_dir("auth-dash")

    File.mkdir_p!(private_dir)

    private_manifest = %{
      "name" => "auth-dash",
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => %{
        "entry" => "index.html",
        "window" => %{"width" => 800, "height" => 600}
      },
      "schema" => %{"tables" => %{}, "queries" => %{}}
    }

    File.write!(Path.join(private_dir, "cyfr-manifest.json"), Jason.encode!(private_manifest))

    File.write!(
      Path.join(private_dir, "index.html"),
      "<html><head></head><body>Auth</body></html>"
    )

    File.write!(Path.join(private_dir, "app.js"), "// auth app")
    File.write!(Path.join(private_dir, "data.db"), "secret db")

    # ── Public tincture (pub-dash) ───────────────────────────────────
    public_dir = tincture_dir("pub-dash")

    File.mkdir_p!(public_dir)

    public_manifest = %{
      "name" => "pub-dash",
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => %{
        "entry" => "index.html",
        "connect" => ["*.supabase.co"]
      },
      "dependencies" => %{
        "static" => [
          %{"ref" => "reagent:local.echo", "reason" => "echo test"}
        ]
      }
    }

    File.write!(Path.join(public_dir, "cyfr-manifest.json"), Jason.encode!(public_manifest))

    File.write!(
      Path.join(public_dir, "index.html"),
      "<html><head></head><body>Public</body></html>"
    )

    File.write!(Path.join(public_dir, "style.css"), "body { margin: 0; }")

    # ── Register components ──────────────────────────────────────────
    # The athanor behind the test context must exist as an active row: the
    # `/t/<athanor>/…` route resolves it by slug ("test") before any lookup.
    ctx = Sanctum.TestContext.local()
    _athanor = Sanctum.TestContext.athanor!()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rl_manifest = %{public_manifest | "name" => "rl-dash"}

    # A manifest whose connect list carries a control character: the domain
    # check has to reject it before it reaches a response header.
    nl_manifest =
      public_manifest
      |> Map.put("name", "nl-dash")
      |> put_in(["tincture", "connect"], ["evil.com\n", "ok.example.com"])

    nl_dir = tincture_dir("nl-dash")
    File.mkdir_p!(nl_dir)
    File.write!(Path.join(nl_dir, "cyfr-manifest.json"), Jason.encode!(nl_manifest))
    File.write!(Path.join(nl_dir, "index.html"), "<html><head></head><body>NL</body></html>")

    # A built tincture: its entry and assets live in the build's dist/.
    built_manifest =
      public_manifest
      |> Map.put("name", "built-dash")
      |> put_in(["tincture", "entry"], "dist/index.html")
      |> put_in(["tincture", "build"], %{"tool" => "vite"})

    built_dir = tincture_dir("built-dash")
    File.mkdir_p!(Path.join([built_dir, "dist", "assets"]))
    File.write!(Path.join(built_dir, "cyfr-manifest.json"), Jason.encode!(built_manifest))

    File.write!(
      Path.join(built_dir, "index.html"),
      "<html><head></head><body>Source</body></html>"
    )

    File.write!(
      Path.join([built_dir, "dist", "index.html"]),
      ~s(<html><head></head><body>Built<script src="./assets/app.js"></script></body></html>)
    )

    File.write!(Path.join([built_dir, "dist", "assets", "app.js"]), "// built")

    for {name, manifest} <- [
          {"auth-dash", private_manifest},
          {"pub-dash", public_manifest},
          {"rl-dash", rl_manifest},
          {"nl-dash", nl_manifest},
          {"built-dash", built_manifest}
        ] do
      {:ok, _} =
        Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
          id: "test_#{name}_#{:rand.uniform(1_000_000)}",
          name: name,
          version: "1.0.0",
          component_type: "tincture",
          description: name,
          tags: "[]",
          digest: digest(name),
          release_digest: release_digest(name),
          size: 100,
          exports: "[]",
          manifest: Jason.encode!(manifest),
          publisher: "local",
          publisher_id: "local|local|testns",
          source: Compendium.Source.filesystem(),
          signature_verified: false,
          inserted_at: now,
          updated_at: now
        })
    end

    # ── Public tincture with a rate-limited policy (rl-dash) ─────────
    # Dedicated fixture for the fail-closed test: its policy carries a rate
    # limit from the start, so no mid-test policy swap / cache invalidation
    # is needed (which proved environment-sensitive in CI).
    rl_dir = tincture_dir("rl-dash")

    File.mkdir_p!(rl_dir)
    File.write!(Path.join(rl_dir, "cyfr-manifest.json"), Jason.encode!(rl_manifest))
    File.write!(Path.join(rl_dir, "index.html"), "<html><head></head><body>RL</body></html>")

    # Public-ness is a published profile now, not a policy bit. Both
    # public fixtures get an active public profile; the pre-dispatch
    # policy rate limiter is gone (rates ride the authority path).

    for name <- ["pub-dash", "rl-dash", "nl-dash", "built-dash"] do
      {:ok, _} =
        Arca.ProfileStorage.put(%{
          id: "prof_#{name}_#{:rand.uniform(1_000_000)}",
          athanor_id: ctx.athanor_id,
          source_ref: "tincture:local.#{name}",
          kind: "public",
          label: "public",
          status: "active"
        })
    end

    on_exit(fn ->
      if original do
        Application.put_env(:arca, :base_path, original)
      else
        Application.delete_env(:arca, :base_path)
      end

      File.rm_rf!(base)
    end)

    %{private_dir: private_dir, public_dir: public_dir}
  end

  # ── A private tincture at its address: served to nobody ─────────

  # A private tincture's files are served only under an asset credential
  # in their path; its address answers as a missing tincture does, whatever
  # credential the request carries.
  describe "private tincture at its address" do
    setup do
      ctx = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())

      {:ok, %{api_key: key}} =
        Sanctum.ApiKey.create(ctx, %{
          name: "tincture-address-key-#{:rand.uniform(1_000_000)}",
          type: :service,
          scope: ["execute", "component_read", "storage_read"]
        })

      {:ok, session} = Sanctum.TestContext.create_session(ctx)
      %{api_key: key, session: session}
    end

    test "is not found without a credential", %{conn: conn} do
      assert get(conn, "/t/test/local/auth-dash").status == 404
      assert get(build_conn(), "/t/test/local/auth-dash/app.js").status == 404
      assert get(build_conn(), "/t/test/local/auth-dash/data.db").status == 404
    end

    test "is not found under an Authorization bearer", %{api_key: key, session: session} do
      for bearer <- [key, session.token],
          path <- ["/t/test/local/auth-dash", "/t/test/local/auth-dash/app.js"] do
        conn = build_conn() |> put_req_header("authorization", "Bearer #{bearer}") |> get(path)
        assert json_response(conn, 404)["code"] == "not_found", path
        refute conn.resp_body =~ "Auth"
      end
    end

    test "the old in-address asset prefix opens nothing", %{session: session} do
      {:ok, ctx} = Sanctum.Caller.establish(session.token)

      {:ok, %{credential: credential}} =
        Sanctum.TinctureAuth.mint_asset_credential(ctx, release_digest("auth-dash"))

      assert get(build_conn(), "/t/test/local/auth-dash/_s/#{credential}/app.js").status == 404
    end
  end

  # ── Public tincture (no auth needed) ─────────────────────────────

  describe "public tincture — unauthenticated" do
    test "serves index.html without authentication", %{conn: conn} do
      conn = get(conn, "/t/test/local/pub-dash")
      assert conn.status == 200
      assert conn.resp_body =~ "Public"
    end

    test "serves a frame: the tincture routes read no session to refuse it for",
         %{conn: conn} do
      page = conn |> put_req_header("sec-fetch-dest", "iframe") |> get("/t/test/local/pub-dash")
      assert page.status == 200
      assert page.resp_body =~ "Public"

      asset =
        build_conn()
        |> put_req_header("sec-fetch-dest", "iframe")
        |> get("/t/test/local/pub-dash/style.css")

      assert asset.status == 200
    end

    test "its policy is the frame's rules' derivation, sandboxed like a private one's",
         %{conn: conn} do
      conn = get(conn, "/t/test/local/pub-dash")
      [csp] = get_resp_header(conn, "content-security-policy")
      [_, nonce] = Regex.run(~r/'nonce-([A-Za-z0-9_-]+)'/, csp)

      {:ok, component} =
        Compendium.inspect_component(Sanctum.TestContext.local(), "tincture:local.pub-dash:1.0.0")

      manifest = component["manifest"]

      # The hand-written policy is gone: connect-src names the endpoint's
      # origin and the declared domains, never `'self'`, and the document
      # is sandboxed.
      assert csp == Emissary.Web.TinctureAssets.csp(manifest, nonce)
      assert csp =~ ~r/connect-src https?:\/\/\S+ https:\/\/\*\.supabase\.co;/
      refute csp =~ "connect-src 'self'"
      assert String.ends_with?(csp, "; sandbox allow-scripts")

      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
      # The address follows the latest version, so it is revalidated.
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
    end

    test "a connect domain with a trailing newline is rejected, not put in a header",
         %{conn: conn} do
      # `~r/^…$/` matches before a trailing newline in Elixir, so "evil.com\n"
      # passed the domain check, reached the CSP string, and
      # `put_resp_header/3` raised on the control character — a manifest could
      # 500 its own tincture's index for good, with nothing pointing at the
      # field. `\A…\z` is the anchor that means what this check meant.
      conn = get(conn, "/t/test/local/nl-dash")

      assert conn.status == 200
      [csp] = get_resp_header(conn, "content-security-policy")
      refute csp =~ "evil.com"
      assert csp =~ "https://ok.example.com"
      refute csp =~ "\n"
    end

    test "a second HTML page gets the tincture's CSP, not the asset lockdown",
         %{conn: conn, public_dir: public_dir} do
      # A multi-page tincture links from its entry to another page. That page
      # is served by the ASSET route, whose pipeline sets
      # `default-src 'none'; frame-ancestors 'none'` — right for a script,
      # fatal for a document: nothing on the page could load and the iframe
      # could not frame it.
      File.write!(Path.join(public_dir, "page2.html"), "<html><body>Two</body></html>")

      conn = get(conn, "/t/test/local/pub-dash/page2.html")

      assert conn.status == 200
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'self'"
      assert csp =~ "frame-ancestors "
      assert csp =~ "; sandbox allow-scripts"
      refute csp =~ "default-src 'none'"
    end

    test "a non-HTML asset keeps the locked-down header", %{conn: conn} do
      conn = get(conn, "/t/test/local/pub-dash/style.css")

      assert conn.status == 200
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'none'"
    end

    test "injects plain base tag (no token) for public tincture", %{conn: conn} do
      conn = get(conn, "/t/test/local/pub-dash")
      assert conn.resp_body =~ ~s(<base href="/t/test/local/pub-dash/">)
      refute conn.resp_body =~ "_s/"
    end

    test "a built entry is served from dist/, and its relative assets resolve there",
         %{conn: conn} do
      page = get(conn, "/t/test/local/built-dash")
      assert page.status == 200
      assert page.resp_body =~ "Built"
      assert page.resp_body =~ ~s(<base href="/t/test/local/built-dash/dist/">)

      asset = get(build_conn(), "/t/test/local/built-dash/dist/assets/app.js")
      assert asset.status == 200
      assert asset.resp_body == "// built"
    end

    test "returns 404 for nonexistent tincture (indistinguishable from private)", %{conn: conn} do
      conn = get(conn, "/t/test/local/nonexistent")
      assert conn.status == 404
    end

    test "does not serve a public tincture from a different athanor", %{conn: conn} do
      # pub-dash is public in the test athanor; another athanor must not
      # resolve it (athanor isolation), and an unknown athanor is a 404 too.
      {:ok, _} =
        Sanctum.Tenancy.Athanors.create(%{
          kind: "group",
          name: "Other",
          slug: "other",
          created_by: "test"
        })

      assert get(conn, "/t/other/local/pub-dash").status == 404
      assert get(conn, "/t/nobody/local/pub-dash").status == 404
    end

    test "an athanor the store cannot resolve is a 503, never a 404", %{conn: conn} do
      assert get(conn, "/t/test/local/pub-dash").status == 200

      # The route's athanor segment is read before any lookup; with the
      # table gone the store cannot say whether it exists.
      Arca.Repo.query!("ALTER TABLE athanors RENAME TO athanors_unavailable")

      for path <- ["/t/test/local/pub-dash", "/t/test/local/pub-dash/style.css"] do
        refused = get(build_conn(), path)
        assert json_response(refused, 503)["code"] == "unavailable"
        assert get_resp_header(refused, "retry-after") == ["5"]
        refute refused.resp_body =~ "Public"
      end
    end
  end

  # ── Assets (no auth required) ────────────────────────────────────

  describe "assets — public tinctures" do
    test "serves public tincture assets with CORS header", %{conn: conn} do
      conn = get(conn, "/t/test/local/pub-dash/style.css")
      assert conn.status == 200
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=3600"]
    end

    test "returns 404 for asset requests for unknown tincture", %{conn: conn} do
      conn = get(conn, "/t/test/local/no-such-tincture/app.js")
      assert conn.status == 404
    end

    test "blocks data.db for public tincture", %{conn: conn} do
      conn = get(conn, "/t/test/local/pub-dash/data.db")
      assert conn.status == 404
    end
  end

  # ── A private tincture version under its asset credential ────────

  describe "a private tincture version under its asset credential" do
    setup do
      # The credential is minted from the reader's own session: a private
      # app's files are theirs to read while that session and their seat
      # stand, not anyone's who has the URL. A second seat keeps the athanor
      # open when the reader leaves it.
      {:ok, _} =
        Sanctum.Tenancy.Members.ensure("usr_keeper", scope: "athanor", athanor_id: "ath_test")

      reader = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
      {:ok, session} = Sanctum.TestContext.create_session(reader)
      {:ok, ctx} = Sanctum.Caller.establish(session.token)

      {:ok, reader: reader, session: session, ctx: ctx}
    end

    defp credential(ctx, name \\ "auth-dash", opts \\ []) do
      {:ok, %{credential: credential}} =
        Sanctum.TinctureAuth.mint_asset_credential(ctx, release_digest(name), opts)

      credential
    end

    defp served(credential, file, name \\ "auth-dash"),
      do: Prima.TinctureUrl.asset_path(credential, ["local", name, "1.0.0" | file])

    test "serves the entry page with the SDK, based under the credential's own path",
         %{conn: conn, ctx: ctx} do
      credential = credential(ctx)
      page = get(conn, served(credential, ["index.html"]))

      assert page.status == 200
      assert page.resp_body =~ "Auth"
      assert page.resp_body =~ "window.cyfr"

      base = Prima.TinctureUrl.asset_path(credential, ["local", "auth-dash", "1.0.0"]) <> "/"
      assert page.resp_body =~ ~s(<base href="#{base}">)

      # The document's policy is the frame's rules' derivation from the
      # version's declaration, with its sandbox: a direct navigation to
      # the page is never a first-party page of this origin.
      [csp] = get_resp_header(page, "content-security-policy")
      [_, nonce] = Regex.run(~r/'nonce-([A-Za-z0-9_-]+)'/, csp)
      {:ok, component} = Compendium.inspect_component(ctx, "tincture:local.auth-dash:1.0.0")
      manifest = component["manifest"]

      assert csp == Emissary.Web.TinctureAssets.csp(manifest, nonce)
      assert String.ends_with?(csp, "; sandbox allow-scripts")
      assert get_resp_header(page, "referrer-policy") == ["no-referrer"]
    end

    test "serves the version's files, cached for no longer than the credential has left",
         %{conn: conn, ctx: ctx} do
      credential = credential(ctx)
      {:ok, %{remaining_s: left}} = Sanctum.TinctureAuth.verify_asset_credential(credential)

      asset = get(conn, served(credential, ["app.js"]))
      assert asset.status == 200
      assert asset.resp_body =~ "auth app"
      # CORS required for sandboxed frames (opaque origin).
      assert get_resp_header(asset, "access-control-allow-origin") == ["*"]
      assert get_resp_header(asset, "referrer-policy") == ["no-referrer"]

      ["private, max-age=" <> seconds] = get_resp_header(asset, "cache-control")
      assert String.to_integer(seconds) in 1..left

      # A shorter window is a shorter lifetime.
      short = credential(ctx, "auth-dash", window_s: 60)

      ["private, max-age=" <> seconds] =
        get_resp_header(get(build_conn(), served(short, ["app.js"])), "cache-control")

      assert String.to_integer(seconds) <= 60
    end

    test "compresses a script for a client that accepts it", %{conn: conn, ctx: ctx} do
      asset =
        conn
        |> put_req_header("accept-encoding", "gzip")
        |> get(served(credential(ctx), ["app.js"]))

      assert get_resp_header(asset, "content-encoding") == ["gzip"]
      assert :zlib.gunzip(asset.resp_body) == "// auth app"
    end

    test "the credential never reaches the request path anything names the request by",
         %{conn: conn, ctx: ctx} do
      credential = credential(ctx)
      asset = get(conn, served(credential, ["app.js"]))

      assert asset.status == 200
      refute asset.request_path =~ credential
      assert asset.request_path == "/_s/[REDACTED]/local/auth-dash/1.0.0/app.js"
    end

    test "no telemetry span or request log names the credential, while routing still reads it",
         %{conn: conn, ctx: ctx} do
      credential = credential(ctx)
      test_pid = self()
      handler = "c1-scrub-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach_many(
          handler,
          [
            [:phoenix, :endpoint, :start],
            [:phoenix, :endpoint, :stop],
            [:phoenix, :router_dispatch, :start]
          ],
          fn event, _measurements, %{conn: seen} = metadata, _config ->
            send(test_pid, {:seen, event, seen.request_path, Map.get(metadata, :route)})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      asset = get(conn, served(credential, ["app.js"]))
      assert asset.status == 200
      assert asset.resp_body =~ "auth app"

      redacted = "/_s/[REDACTED]/local/auth-dash/1.0.0/app.js"

      for event <- [[:phoenix, :endpoint, :start], [:phoenix, :endpoint, :stop]] do
        assert_received {:seen, ^event, ^redacted, _route}
      end

      # The dispatch names the route by its pattern, not the path.
      assert_received {:seen, [:phoenix, :router_dispatch, :start], ^redacted, "/_s/*path"}
      refute_received {:seen, _event, _path_with_credential, _route}
    end

    test "never serves a reserved file", %{conn: conn, ctx: ctx} do
      assert json_response(get(conn, served(credential(ctx), ["data.db"])), 404)["code"] ==
               "not_found"
    end

    test "serves only the version whose digest the credential names", %{conn: conn, ctx: ctx} do
      # Another tincture's path, a version the athanor does not hold, and a
      # credential for another digest: none is this credential's version.
      credential = credential(ctx)
      assert get(conn, served(credential, ["index.html"], "pub-dash")).status == 404

      missing =
        Prima.TinctureUrl.asset_path(credential, ["local", "auth-dash", "9.9.9", "app.js"])

      assert get(build_conn(), missing).status == 404

      other = credential(ctx, "pub-dash")
      assert get(build_conn(), served(other, ["app.js"])).status == 404
      assert get(build_conn(), served(other, ["style.css"], "pub-dash")).status == 200

      # The version's identity is its release digest: a credential naming
      # its bare artifact digest, which a manifest change would leave
      # standing, opens nothing.
      {:ok, %{credential: artifact}} =
        Sanctum.TinctureAuth.mint_asset_credential(ctx, digest("auth-dash"))

      assert get(build_conn(), served(artifact, ["app.js"])).status == 404
    end

    test "a credential this server did not sign is refused by name", %{conn: conn} do
      forged = String.duplicate("A", 40) <> "." <> String.duplicate("B", 40)
      refused = get(conn, served(forged, ["app.js"]))
      assert json_response(refused, 401)["code"] == "unauthenticated"
      refute Enum.any?(get_resp_header(refused, "cache-control"), &(&1 =~ "private, max-age"))

      # A segment outside the credential grammar is no served file at all.
      assert get(build_conn(), "/_s/short/local/auth-dash/1.0.0/app.js").status == 404
    end

    test "a file requested after the window is refused", %{conn: conn, ctx: ctx} do
      credential = credential(ctx, "auth-dash", window_s: 1)
      path = served(credential, ["app.js"])

      assert get(conn, path).status in [200, 401]

      wait_until(
        fn -> get(build_conn(), path).status == 401 end,
        5_000,
        "the one-second credential to expire"
      )

      assert json_response(get(build_conn(), path), 401)["code"] == "unauthenticated"
    end

    test "a retired source refuses the next request under its credential",
         %{conn: conn, ctx: ctx, session: session} do
      credential = credential(ctx)
      assert get(conn, served(credential, ["app.js"])).status == 200

      :ok = Sanctum.Session.destroy(session.token)
      gone = get(build_conn(), served(credential, ["app.js"]))
      assert json_response(gone, 403)["code"] == "forbidden"
      refute gone.resp_body =~ "auth app"
    end

    test "a reader who left the athanor is refused by name",
         %{conn: conn, ctx: ctx, reader: reader} do
      credential = credential(ctx)
      {:ok, athanor} = Sanctum.Tenancy.Athanors.get("ath_test")
      :ok = Sanctum.Tenancy.Members.remove_member(athanor, user_id: reader.user_id)

      assert json_response(get(conn, served(credential, ["app.js"])), 403)["code"] ==
               "forbidden"
    end

    test "a key's allowlist holds its credential: admitted address served, other refused" do
      ctx = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())

      {:ok, %{api_key: key}} =
        Sanctum.ApiKey.create(ctx, %{
          name: "allowlisted-#{:rand.uniform(1_000_000)}",
          type: :service,
          scope: ["execute", "component_read", "storage_read"],
          ip_allowlist: ["127.0.0.1"]
        })

      {:ok, key_ctx} = Sanctum.Caller.establish({:api_key, key}, client_ip: "127.0.0.1")
      key_ctx = %{key_ctx | client_ip: "127.0.0.1"}
      path = served(credential(key_ctx), ["app.js"])

      assert get(build_conn(), path).status == 200

      elsewhere = get(%{build_conn() | remote_ip: {198, 51, 100, 1}}, path)
      assert json_response(elsewhere, 403)["code"] == "forbidden"
    end

    test "a store that cannot answer serves nothing", %{conn: conn, ctx: ctx} do
      path = served(credential(ctx), ["app.js"])
      Arca.Repo.query!("ALTER TABLE sessions RENAME TO sessions_unavailable")

      asset = get(conn, path)
      assert json_response(asset, 503)["code"] == "unavailable"
      assert get_resp_header(asset, "retry-after") == ["5"]
      refute asset.resp_body =~ "auth app"
    end

    test "a registry that cannot say which version it holds serves nothing, and says so",
         %{conn: conn, ctx: ctx} do
      path = served(credential(ctx), ["app.js"])
      Arca.Repo.query!("ALTER TABLE components RENAME TO components_unavailable")

      asset = get(conn, path)
      assert json_response(asset, 503)["code"] == "unavailable"
      refute asset.resp_body =~ "auth app"
    end
  end

  describe "transport rate limiting" do
    setup do
      # Earlier tests in this file already counted requests under the disabled
      # (1M) limit — start these from a clean slate, then lower the limit.
      Prima.RateLimiter.reset()
      Application.put_env(:cyfr, :tincture_rate_limit_max, 2)

      on_exit(fn ->
        Application.put_env(:cyfr, :tincture_rate_limit_max, 1_000_000)
        Prima.RateLimiter.reset()
      end)

      :ok
    end

    test "page requests over the limit get 429 with retry-after", %{conn: conn} do
      for _ <- 1..2 do
        assert get(build_conn(), "/t/test/local/pub-dash").status != 429
      end

      blocked = get(build_conn(), "/t/test/local/pub-dash")
      assert blocked.status == 429
      assert get_resp_header(blocked, "retry-after") != []

      # Other tinctures are unaffected (separate bucket key).
      assert get(build_conn(), "/t/test/local/auth-dash").status != 429
      _ = conn
    end

    test "asset requests over the limit get 429", %{conn: _conn} do
      for _ <- 1..2 do
        assert get(build_conn(), "/t/test/local/pub-dash/app.js").status != 429
      end

      assert get(build_conn(), "/t/test/local/pub-dash/app.js").status == 429
    end
  end
end
