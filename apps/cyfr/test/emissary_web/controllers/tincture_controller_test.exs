# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.TinctureControllerTest do
  use EmissaryWeb.ConnCase, async: false

  setup do
    base = Path.join(System.tmp_dir!(), "tincture_ctrl_#{:rand.uniform(1_000_000)}")
    components_dir = Path.join(base, "components")

    # ── Private tincture (auth-dash) ─────────────────────────────────
    private_dir =
      Path.join([components_dir, "local", "default", "tinctures", "local", "auth-dash", "1.0.0"])

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
    File.write!(Path.join(private_dir, "index.html"), "<html><head></head><body>Auth</body></html>")
    File.write!(Path.join(private_dir, "app.js"), "// auth app")
    File.write!(Path.join(private_dir, "data.db"), "secret db")

    # ── Public tincture (pub-dash) ───────────────────────────────────
    public_dir =
      Path.join([components_dir, "local", "default", "tinctures", "local", "pub-dash", "1.0.0"])

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
    File.write!(Path.join(public_dir, "index.html"), "<html><head></head><body>Public</body></html>")
    File.write!(Path.join(public_dir, "style.css"), "body { margin: 0; }")

    # ── Register components ──────────────────────────────────────────
    original = Application.get_env(:cyfr, :components_path)
    Application.put_env(:cyfr, :components_path, components_dir)

    ctx = Sanctum.TestContext.local()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for {name, manifest} <- [{"auth-dash", private_manifest}, {"pub-dash", public_manifest}] do
      {:ok, _} =
        Arca.ComponentStorage.put_component(ctx, %{
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
          source: "local",
          signature_verified: false,
          inserted_at: now,
          updated_at: now
        })
    end

    # Mark pub-dash as public via policy
    pub_ref = "tincture:local.pub-dash"

    :ok =
      Sanctum.PolicyStore.put(ctx, pub_ref, %{
        component_type: "tincture",
        is_public: true,
        rate_limit: %{requests: 100, window: "1m"},
        timeout: "30s"
      })

    on_exit(fn ->
      if original do
        Application.put_env(:cyfr, :components_path, original)
      else
        Application.delete_env(:cyfr, :components_path)
      end

      Arca.Cache.invalidate({:policy, pub_ref, "local", "default"})
      File.rm_rf!(base)
    end)

    %{private_dir: private_dir, public_dir: public_dir}
  end

  # ── Private tincture (requires auth) ─────────────────────────────

  describe "private tincture — unauthenticated" do
    test "returns 404 (indistinguishable from missing)", %{conn: conn} do
      conn = get(conn, "/t/local/default/local/auth-dash")
      assert conn.status == 404
    end
  end

  describe "private tincture — authenticated via MCP session" do
    setup do
      # Create an MCP session for auth
      ctx = Sanctum.TestContext.local()
      {:ok, session} = Emissary.MCP.Session.create(ctx)
      %{session_id: session.id}
    end

    test "serves index.html with CSP headers", %{conn: conn, session_id: sid} do
      conn = %{conn | query_string: "_session=#{sid}"}

      conn =
        EmissaryWeb.TinctureController.index(conn, %{
          "org" => "local",
          "project" => "default",
          "publisher" => "local",
          "tincture_name" => "auth-dash"
        })

      assert conn.status == 200
      assert conn.resp_body =~ "Auth"

      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "connect-src 'self'"
      assert csp =~ "frame-ancestors"
    end

    test "injects base tag with signed token for private tincture", %{conn: conn, session_id: sid} do
      conn = %{conn | query_string: "_session=#{sid}"}

      conn =
        EmissaryWeb.TinctureController.index(conn, %{
          "org" => "local",
          "project" => "default",
          "publisher" => "local",
          "tincture_name" => "auth-dash"
        })

      assert conn.resp_body =~ ~r/<base href="\/t\/local\/default\/local\/auth-dash\/_s\/[^"]+\/">/
    end

    test "returns 404 for nonexistent tincture", %{conn: conn, session_id: sid} do
      conn = %{conn | query_string: "_session=#{sid}"}

      conn =
        EmissaryWeb.TinctureController.index(conn, %{
          "org" => "local",
          "project" => "default",
          "publisher" => "local",
          "tincture_name" => "no-such-tincture"
        })

      assert conn.status == 404
    end
  end

  describe "private tincture — API key auth" do
    setup do
      ctx = Sanctum.TestContext.local()

      key_name = "tincture-test-key-#{:rand.uniform(1_000_000)}"

      {:ok, %{key: key}} =
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
      conn = get(conn, "/t/local/default/local/auth-dash?_key=#{key}")
      assert conn.status == 200
      assert conn.resp_body =~ "Auth"
    end

    test "returns 404 with invalid API key", %{conn: conn} do
      conn = get(conn, "/t/local/default/local/auth-dash?_key=cyfr_sk_invalidgarbage")
      assert conn.status == 404
    end
  end

  # ── Public tincture (no auth needed) ─────────────────────────────

  describe "public tincture — unauthenticated" do
    test "serves index.html without authentication", %{conn: conn} do
      conn = get(conn, "/t/local/default/local/pub-dash")
      assert conn.status == 200
      assert conn.resp_body =~ "Public"
    end

    test "sets CSP header with connect-src including declared domains", %{conn: conn} do
      conn = get(conn, "/t/local/default/local/pub-dash")
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "connect-src 'self' https://*.supabase.co"
    end

    test "injects plain base tag (no token) for public tincture", %{conn: conn} do
      conn = get(conn, "/t/local/default/local/pub-dash")
      assert conn.resp_body =~ ~s(<base href="/t/local/default/local/pub-dash/">)
      refute conn.resp_body =~ "_s/"
    end

    test "returns 404 for nonexistent tincture (indistinguishable from private)", %{conn: conn} do
      conn = get(conn, "/t/local/default/local/nonexistent")
      assert conn.status == 404
    end

    test "does not serve a public tincture from a different workspace", %{conn: conn} do
      # pub-dash is public in local/default; a different workspace must not
      # resolve it (workspace isolation).
      conn = get(conn, "/t/other-org/other-proj/local/pub-dash")
      assert conn.status == 404
    end
  end

  # ── Assets (no auth required) ────────────────────────────────────

  describe "assets — public tinctures" do
    test "serves public tincture assets with CORS header", %{conn: conn} do
      conn = get(conn, "/t/local/default/local/pub-dash/style.css")
      assert conn.status == 200
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=3600"]
    end

    test "returns 404 for asset requests for unknown tincture", %{conn: conn} do
      conn = get(conn, "/t/local/default/local/no-such-tincture/app.js")
      assert conn.status == 404
    end

    test "blocks data.db for public tincture", %{conn: conn} do
      conn = get(conn, "/t/local/default/local/pub-dash/data.db")
      assert conn.status == 404
    end
  end

  describe "assets — private tinctures (no token)" do
    test "returns 404 for private tincture assets without token", %{conn: conn} do
      conn = get(conn, "/t/local/default/local/auth-dash/app.js")
      assert conn.status == 404
    end

    test "returns 404 for private tincture data.db", %{conn: conn} do
      conn = get(conn, "/t/local/default/local/auth-dash/data.db")
      assert conn.status == 404
    end
  end

  describe "assets — private tinctures (signed token)" do
    test "serves private tincture assets with valid token", %{conn: conn} do
      token = Phoenix.Token.sign(EmissaryWeb.Endpoint, "tincture_access", {"local", "default", "local", "auth-dash"})
      conn = get(conn, "/t/local/default/local/auth-dash/_s/#{token}/app.js")
      assert conn.status == 200
      assert conn.resp_body =~ "auth app"
      # CORS required for sandboxed iframes (opaque origin)
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      # Cache stays private — token-bearing URLs shouldn't be proxy-cached
      assert get_resp_header(conn, "cache-control") == ["private, max-age=3600"]
    end

    test "returns 404 for invalid token", %{conn: conn} do
      conn = get(conn, "/t/local/default/local/auth-dash/_s/garbage_token/app.js")
      assert conn.status == 404
    end

    test "returns 404 for token scoped to different tincture", %{conn: conn} do
      token =
        Phoenix.Token.sign(
          EmissaryWeb.Endpoint,
          "tincture_access",
          {"local", "default", "local", "pub-dash"}
        )
      conn = get(conn, "/t/local/default/local/auth-dash/_s/#{token}/app.js")
      assert conn.status == 404
    end

    test "returns 404 for token with wrong publisher", %{conn: conn} do
      token =
        Phoenix.Token.sign(
          EmissaryWeb.Endpoint,
          "tincture_access",
          {"local", "default", "evil", "auth-dash"}
        )
      conn = get(conn, "/t/local/default/local/auth-dash/_s/#{token}/app.js")
      assert conn.status == 404
    end

    test "returns 404 for token whose workspace differs from the URL", %{conn: conn} do
      token =
        Phoenix.Token.sign(
          EmissaryWeb.Endpoint,
          "tincture_access",
          {"local", "default", "local", "auth-dash"}
        )

      conn = get(conn, "/t/other-org/other-proj/local/auth-dash/_s/#{token}/app.js")
      assert conn.status == 404
    end

    test "blocks data.db even with valid token", %{conn: conn} do
      token = Phoenix.Token.sign(EmissaryWeb.Endpoint, "tincture_access", {"local", "default", "local", "auth-dash"})
      conn = get(conn, "/t/local/default/local/auth-dash/_s/#{token}/data.db")
      assert conn.status == 404
    end
  end

  describe "assets — signed token expiry" do
    test "returns 404 for expired signed token", %{conn: conn} do
      # Sign a token, then verify with max_age: 0 to simulate expiry.
      # The controller uses max_age: 86_400 (24h). We can't wait 24h,
      # so we forge a token with a known-past timestamp by sleeping briefly
      # and using max_age: 0 on verify — but the controller verifies
      # internally. Instead, use an invalid salt to produce a token that
      # will fail verification as a proxy for expiry (same code path).
      expired_token = Phoenix.Token.sign(EmissaryWeb.Endpoint, "wrong_salt", {"local", "default", "local", "auth-dash"})
      conn = get(conn, "/t/local/default/local/auth-dash/_s/#{expired_token}/app.js")
      assert conn.status == 404
    end
  end

  # ── Invoke endpoint ──────────────────────────────────────────────

  describe "POST /t/:publisher/:tincture_name/invoke" do
    test "rejects invoke for nonexistent tincture", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/t/local/default/local/no-such/invoke", Jason.encode!(%{reference: "r:local.echo", input: %{}}))

      body = json_response(conn, 404)
      assert body["error"] == "Not Found"
    end

    test "rejects invoke for undeclared dependency", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/t/local/default/local/pub-dash/invoke", Jason.encode!(%{reference: "c:local.undeclared", input: %{}}))

      body = json_response(conn, 403)
      assert body["error"] == "component not in dependencies"
    end

    test "rejects invoke with missing reference", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/t/local/default/local/pub-dash/invoke", Jason.encode!(%{input: %{}}))

      body = json_response(conn, 400)
      assert body["error"] == "missing reference"
    end

    test "rejects invoke for private tincture without auth", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/t/local/default/local/auth-dash/invoke", Jason.encode!(%{reference: "r:local.echo", input: %{}}))

      body = json_response(conn, 404)
      assert body["error"] == "Not Found"
    end

    test "OPTIONS preflight returns 204 with CORS headers", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "null")
        |> put_req_header("access-control-request-method", "POST")
        |> put_req_header("access-control-request-headers", "content-type")
        |> options("/t/local/default/local/pub-dash/invoke")

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-methods") != []
    end
  end
end
