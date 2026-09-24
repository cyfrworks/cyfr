# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.TinctureControllerTest do
  use EmissaryWeb.ConnCase, async: false

  require Ecto.Query

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
          digest: "sha256:test_#{name}",
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

  # ── Private tincture (requires auth) ─────────────────────────────

  describe "private tincture — unauthenticated" do
    test "returns 404 (indistinguishable from missing)", %{conn: conn} do
      conn = get(conn, "/t/test/local/auth-dash")
      assert conn.status == 404
    end
  end

  # Was "authenticated via MCP session header". That header carried the same
  # Sanctum session token the bearer branch already resolves, so it was a second
  # spelling of one credential, and it went out with the protocol session it was
  # named for.
  #
  # These tests are about what a private tincture *renders* — CSP headers, the
  # injected base tag — not about which credential got in, so they use the
  # simplest working one. That the bearer session token authenticates at all is
  # asserted directly in `Sanctum.TinctureAuthTest`, which is where the auth
  # chain lives.
  describe "private tincture — rendering under an authenticated caller" do
    setup do
      ctx = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())

      {:ok, %{api_key: key}} =
        Sanctum.ApiKey.create(ctx, %{
          name: "tincture-render-key-#{:rand.uniform(1_000_000)}",
          type: :service,
          scope: ["execute", "component_read", "storage_read"]
        })

      %{session_token: key}
    end

    test "serves index.html with CSP headers", %{conn: conn, session_token: token} do
      conn = put_req_header(conn, "authorization", "Bearer #{token}")

      conn =
        EmissaryWeb.TinctureController.index(conn, %{
          "athanor" => "test",
          "publisher" => "local",
          "tincture_name" => "auth-dash"
        })

      assert conn.status == 200
      assert conn.resp_body =~ "Auth"

      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "connect-src 'self'"
      # one origin: a tincture may be framed by Prism and by nothing else
      assert csp =~ "frame-ancestors 'self'"
      refute csp =~ "frame-ancestors *"
    end

    test "injects base tag with signed token for private tincture", %{
      conn: conn,
      session_token: token
    } do
      conn = put_req_header(conn, "authorization", "Bearer #{token}")

      conn =
        EmissaryWeb.TinctureController.index(conn, %{
          "athanor" => "test",
          "publisher" => "local",
          "tincture_name" => "auth-dash"
        })

      assert conn.resp_body =~
               ~r/<base href="\/t\/test\/local\/auth-dash\/_s\/[^"]+\/">/
    end

    test "returns 404 for nonexistent tincture", %{conn: conn, session_token: token} do
      # Was `?_session=` in the query string. Account credentials stopped being
      # accepted from tincture URLs; this only kept passing because a missing
      # tincture 404s whether or not the caller authenticated.
      conn = put_req_header(conn, "authorization", "Bearer #{token}")

      conn =
        EmissaryWeb.TinctureController.index(conn, %{
          "athanor" => "test",
          "publisher" => "local",
          "tincture_name" => "no-such-tincture"
        })

      assert conn.status == 404
    end
  end

  describe "private tincture — API key auth" do
    setup do
      ctx = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())

      key_name = "tincture-test-key-#{:rand.uniform(1_000_000)}"

      {:ok, %{api_key: key}} =
        Sanctum.ApiKey.create(ctx, %{
          name: key_name,
          type: :service,
          scope: ["execute", "component_read", "storage_read"]
        })

      on_exit(fn ->
        try do
          Sanctum.ApiKey.revoke(ctx, key_name)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end
      end)

      %{api_key: key}
    end

    test "serves private tincture with valid API key", %{conn: conn, api_key: key} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/t/test/local/auth-dash")

      assert conn.status == 200
      assert conn.resp_body =~ "Auth"
    end

    test "an API key in the query string does not authenticate", %{conn: conn, api_key: key} do
      # Account credentials must be rejected in query parameters, even when valid.
      conn = get(conn, "/t/test/local/auth-dash?_key=#{key}")
      assert conn.status == 404
    end

    test "returns 404 with invalid API key", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer cyfr_sk_invalidgarbage")
        |> get("/t/test/local/auth-dash")

      assert conn.status == 404
    end
  end

  # ── Public tincture (no auth needed) ─────────────────────────────

  describe "public tincture — unauthenticated" do
    test "serves index.html without authentication", %{conn: conn} do
      conn = get(conn, "/t/test/local/pub-dash")
      assert conn.status == 200
      assert conn.resp_body =~ "Public"
    end

    test "sets CSP header with connect-src including declared domains", %{conn: conn} do
      conn = get(conn, "/t/test/local/pub-dash")
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "connect-src 'self' https://*.supabase.co"
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
      assert csp =~ "frame-ancestors 'self'"
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

  describe "assets — private tinctures (no token)" do
    test "returns 404 for private tincture assets without token", %{conn: conn} do
      conn = get(conn, "/t/test/local/auth-dash/app.js")
      assert conn.status == 404
    end

    test "returns 404 for private tincture data.db", %{conn: conn} do
      conn = get(conn, "/t/test/local/auth-dash/data.db")
      assert conn.status == 404
    end
  end

  describe "assets — private tinctures (signed token)" do
    setup do
      # The prefix is minted from the reader's own session: a private app's
      # own assets are theirs to read while that session and their seat
      # stand, not anyone's who has the URL. A second seat keeps the estate
      # open when the reader leaves it.
      {:ok, _} =
        Sanctum.Tenancy.Members.ensure("usr_keeper", scope: "athanor", athanor_id: "ath_test")

      reader = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
      {:ok, session} = Sanctum.TestContext.create_session(reader)
      {:ok, ctx} = Sanctum.Caller.establish(session.token)

      {:ok, reader: reader, ctx: ctx}
    end

    test "serves private tincture assets with valid token", %{conn: conn, ctx: ctx} do
      token = asset_token(ctx)

      conn = get(conn, "/t/test/local/auth-dash/_s/#{token}/app.js")
      assert conn.status == 200
      assert conn.resp_body =~ "auth app"
      # CORS required for sandboxed iframes (opaque origin)
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      # Cache stays private — token-bearing URLs shouldn't be proxy-cached
      assert get_resp_header(conn, "cache-control") == ["private, max-age=3600"]
    end

    test "a prefix minted for someone else opens nothing — by name", %{
      conn: conn,
      ctx: ctx,
      reader: reader
    } do
      # The URL is the whole credential a sandboxed iframe has, so a shared
      # one must not be a shared key: it is held to the seat its reader held.
      # A reader who left is refused as such, not hidden behind a 404 — the
      # signed URL already names the tincture.
      token = asset_token(ctx)
      {:ok, athanor} = Sanctum.Tenancy.Athanors.get("ath_test")
      :ok = Sanctum.Tenancy.Members.remove_member(athanor, user_id: reader.user_id)

      conn = get(conn, "/t/test/local/auth-dash/_s/#{token}/app.js")
      assert conn.status == 403
      assert json_response(conn, 403)["code"] == "not_member"
    end

    test "an invalid token is refused by name", %{conn: conn} do
      conn = get(conn, "/t/test/local/auth-dash/_s/garbage_token/app.js")
      assert conn.status == 401
      assert json_response(conn, 401)["code"] == "asset_token_invalid"
    end

    test "a token scoped to a different tincture is refused as invalid", %{conn: conn, ctx: ctx} do
      token = asset_token(ctx, "local", "pub-dash")

      conn = get(conn, "/t/test/local/auth-dash/_s/#{token}/app.js")
      assert conn.status == 401
      assert json_response(conn, 401)["code"] == "asset_token_invalid"
    end

    test "a token with the wrong publisher is refused as invalid", %{conn: conn, ctx: ctx} do
      token = asset_token(ctx, "evil", "auth-dash")

      conn = get(conn, "/t/test/local/auth-dash/_s/#{token}/app.js")
      assert conn.status == 401
      assert json_response(conn, 401)["code"] == "asset_token_invalid"
    end

    test "a token whose athanor differs from the URL is refused as invalid", %{
      conn: conn,
      ctx: ctx
    } do
      token = asset_token(ctx)

      {:ok, _} =
        Sanctum.Tenancy.Athanors.create(%{
          kind: "group",
          name: "Other",
          slug: "other",
          created_by: "test"
        })

      conn = get(conn, "/t/other/local/auth-dash/_s/#{token}/app.js")
      assert conn.status == 401
      assert json_response(conn, 401)["code"] == "asset_token_invalid"
    end

    test "blocks data.db even with valid token", %{conn: conn, ctx: ctx} do
      token = asset_token(ctx)

      conn = get(conn, "/t/test/local/auth-dash/_s/#{token}/data.db")
      assert conn.status == 404
    end
  end

  defp asset_token(ctx, publisher \\ "local", name \\ "auth-dash") do
    {:ok, token} = Sanctum.TinctureAuth.issue_asset_token(ctx, publisher, name)
    token
  end

  describe "the derived tokens over HTTP" do
    setup do
      {:ok, _} =
        Sanctum.Tenancy.Members.ensure("usr_keeper", scope: "athanor", athanor_id: "ath_test")

      reader = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
      {:ok, session} = Sanctum.TestContext.create_session(reader)
      {:ok, reader: reader, session: session}
    end

    defp base_token(html) do
      [_, token] = Regex.run(~r/<base href="\/t\/test\/local\/auth-dash\/_s\/([^\/"]+)\/">/, html)
      token
    end

    test "the index's asset prefix opens the assets, and dies with the session it came from",
         %{conn: conn, session: session} do
      page =
        conn
        |> put_req_header("authorization", "Bearer #{session.token}")
        |> get("/t/test/local/auth-dash")

      token = base_token(page.resp_body)
      assert get(build_conn(), "/t/test/local/auth-dash/_s/#{token}/app.js").status == 200

      :ok = Sanctum.Session.destroy(session.token)
      gone = get(build_conn(), "/t/test/local/auth-dash/_s/#{token}/app.js")
      assert json_response(gone, 403)["code"] == "not_standing"
    end

    test "a ?_t= token opens no more than its :execute: no private index, no asset prefix",
         %{conn: conn, session: session} do
      minted =
        conn
        |> put_req_header("authorization", "Bearer #{session.token}")
        |> get("/t/access-token?publisher=local&tincture_name=auth-dash")
        |> json_response(200)

      # Reading a private tincture's files takes `:storage_read`, which a
      # token derived for one tincture's `:execute` does not carry; the
      # derivative never widens what its source's policy grants it.
      page = get(build_conn(), "/t/test/local/auth-dash?_t=#{minted["token"]}")
      assert page.status == 404
      refute page.resp_body =~ "_s/"
    end

    test "a credential that cannot mint renders a named refusal, never a URL", %{conn: conn} do
      # A key whose creator is none of this server's people: it stands as a
      # key, and it mints nothing.
      ctx = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())

      {:ok, %{api_key: key}} =
        Sanctum.ApiKey.create(ctx, %{name: "orphan-#{:rand.uniform(1_000_000)}"})

      {1, _} =
        Arca.Repo.update_all(
          Ecto.Query.from(k in Arca.Schemas.ApiKey, where: k.created_by == ^ctx.user_id),
          set: [created_by: "system"]
        )

      mint =
        conn
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/t/access-token?publisher=local&tincture_name=auth-dash")

      body = json_response(mint, 403)
      assert body["code"] == "missing_generation"
      refute Map.has_key?(body, "token")

      page =
        build_conn()
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/t/test/local/auth-dash")

      assert json_response(page, 403)["code"] == "missing_generation"
      refute page.resp_body =~ "_s/"
    end

    test "a key's allowlist holds its derived tokens: admitted address served, other refused",
         %{conn: conn} do
      ctx = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())

      {:ok, %{api_key: key}} =
        Sanctum.ApiKey.create(ctx, %{
          name: "allowlisted-#{:rand.uniform(1_000_000)}",
          type: :service,
          scope: ["execute", "component_read", "storage_read"],
          ip_allowlist: ["127.0.0.1"]
        })

      mint =
        conn
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/t/access-token?publisher=local&tincture_name=auth-dash")

      assert json_response(mint, 200)["token"]

      page =
        build_conn()
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/t/test/local/auth-dash")

      token = base_token(page.resp_body)
      assert get(build_conn(), "/t/test/local/auth-dash/_s/#{token}/app.js").status == 200

      elsewhere =
        %{build_conn() | remote_ip: {198, 51, 100, 1}}
        |> get("/t/test/local/auth-dash/_s/#{token}/app.js")

      assert json_response(elsewhere, 403)["code"] == "ip_not_allowed"
    end

    test "a store that cannot answer serves nothing", %{conn: conn, session: session} do
      page =
        conn
        |> put_req_header("authorization", "Bearer #{session.token}")
        |> get("/t/test/local/auth-dash")

      token = base_token(page.resp_body)
      Arca.Repo.query!("ALTER TABLE sessions RENAME TO sessions_unavailable")

      asset = get(build_conn(), "/t/test/local/auth-dash/_s/#{token}/app.js")
      assert json_response(asset, 503)["code"] == "unavailable"
      refute asset.resp_body =~ "auth app"

      # The private index, asked with the session, answers the same: the
      # store cannot say whether the caller stands, so nothing is served.
      index =
        build_conn()
        |> put_req_header("authorization", "Bearer #{session.token}")
        |> get("/t/test/local/auth-dash")

      assert json_response(index, 503)["code"] == "unavailable"
      assert get_resp_header(index, "retry-after") == ["5"]
      refute index.resp_body =~ "Auth"

      mint =
        build_conn()
        |> put_req_header("authorization", "Bearer #{session.token}")
        |> get("/t/access-token?publisher=local&tincture_name=auth-dash")

      assert json_response(mint, 503)["code"] == "unavailable"
    end
  end

  describe "assets — signed token expiry" do
    test "a dead signed token is refused by name", %{conn: conn} do
      # The controller verifies internally, so expiry cannot be waited out
      # here: a token under the wrong salt fails the same verification the
      # same way, which is the path under test.
      expired_token =
        Phoenix.Token.sign(
          EmissaryWeb.Endpoint,
          "wrong_salt",
          {"test", "local", "auth-dash"}
        )

      conn = get(conn, "/t/test/local/auth-dash/_s/#{expired_token}/app.js")
      assert conn.status == 401
      assert json_response(conn, 401)["code"] == "asset_token_invalid"
    end
  end

  # ── Invoke endpoint ──────────────────────────────────────────────

  describe "POST /t/:publisher/:tincture_name/invoke" do
    test "rejects invoke for nonexistent tincture", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          "/t/test/local/no-such/invoke",
          Jason.encode!(%{reference: "r:local.echo", input: %{}})
        )

      body = json_response(conn, 404)
      assert body["code"] == "not_found"
    end

    test "rejects invoke with missing reference", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/t/test/local/pub-dash/invoke", Jason.encode!(%{input: %{}}))

      body = json_response(conn, 400)
      assert body["error"] == "missing reference"
    end

    test "rejects invoke for private tincture without auth", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          "/t/test/local/auth-dash/invoke",
          Jason.encode!(%{reference: "r:local.echo", input: %{}})
        )

      body = json_response(conn, 404)
      assert body["code"] == "not_found"
    end

    test "OPTIONS preflight returns 204 with CORS headers", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "null")
        |> put_req_header("access-control-request-method", "POST")
        |> put_req_header("access-control-request-headers", "content-type")
        |> options("/t/test/local/pub-dash/invoke")

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-methods") != []
    end
  end

  describe "transport rate limiting" do
    setup do
      # Earlier tests in this file already counted requests under the disabled
      # (1M) limit — start these from a clean slate, then lower the limit.
      Cyfr.RateLimiter.reset()
      Application.put_env(:cyfr, :tincture_rate_limit_max, 2)

      on_exit(fn ->
        Application.put_env(:cyfr, :tincture_rate_limit_max, 1_000_000)
        Cyfr.RateLimiter.reset()
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

    test "invoke requests over the limit get 429 before reaching the controller",
         %{conn: _conn} do
      # Missing reference → 400 in the controller; keeps the request from
      # reaching the executor (unavailable in standalone cyfr runs) while
      # still exercising the limiter, which runs before the controller.
      post_invoke = fn ->
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/t/test/local/pub-dash/invoke", Jason.encode!(%{input: %{}}))
      end

      for _ <- 1..2 do
        assert post_invoke.().status == 400
      end

      assert post_invoke.().status == 429
    end

    test "OPTIONS preflights are not counted against the invoke limit", %{conn: _conn} do
      preflight = fn ->
        build_conn()
        |> put_req_header("origin", "null")
        |> put_req_header("access-control-request-method", "POST")
        |> options("/t/test/local/pub-dash/invoke")
      end

      for _ <- 1..5 do
        assert preflight.().status == 204
      end
    end
  end
end
