defmodule PrismWeb.TinctureControllerTest do
  use PrismWeb.ConnCase, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    base = Path.join(System.tmp_dir!(), "tincture_ctrl_#{:rand.uniform(1_000_000)}")
    components_dir = Path.join(base, "components")

    # ── Private tincture (auth-dash) ─────────────────────────────────
    private_dir =
      Path.join([components_dir, "tinctures", "local", "auth-dash", "1.0.0"])

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
      Path.join([components_dir, "tinctures", "local", "pub-dash", "1.0.0"])

    File.mkdir_p!(public_dir)

    public_manifest = %{
      "name" => "pub-dash",
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => %{"entry" => "index.html"},
      "schema" => %{
        "tables" => %{
          "items" => %{
            "columns" => [
              %{"name" => "id", "type" => "INTEGER", "not_null" => true},
              %{"name" => "label", "type" => "TEXT"}
            ],
            "primary_key" => ["id"]
          }
        },
        "queries" => %{
          "all_items" => %{
            "sql" => "SELECT id, label FROM items ORDER BY id",
            "params" => %{},
            "cache_ttl" => 60
          }
        }
      }
    }

    File.write!(Path.join(public_dir, "cyfr-manifest.json"), Jason.encode!(public_manifest))
    File.write!(Path.join(public_dir, "index.html"), "<html><head></head><body>Public</body></html>")
    File.write!(Path.join(public_dir, "style.css"), "body { margin: 0; }")

    # Create and populate data.db for query tests
    db_path = Path.join(public_dir, "data.db")
    {:ok, db_conn} = Exqlite.Sqlite3.open(db_path)
    :ok = Exqlite.Sqlite3.execute(db_conn, "CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT)")
    :ok = Exqlite.Sqlite3.execute(db_conn, "INSERT INTO items VALUES (1, 'alpha')")
    :ok = Exqlite.Sqlite3.execute(db_conn, "INSERT INTO items VALUES (2, 'beta')")
    :ok = Exqlite.Sqlite3.close(db_conn)

    # ── Register components ──────────────────────────────────────────
    original = Application.get_env(:cyfr, :components_path)
    Application.put_env(:cyfr, :components_path, components_dir)

    ctx = Sanctum.Context.local()
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
          publisher_id: "local_user",
          source: "local",
          signature_verified: false,
          inserted_at: now,
          updated_at: now
        })
    end

    # Mark pub-dash as public
    vis_key = {:tincture_visibility, "", "default", "local", "pub-dash"}

    Arca.Cache.put(vis_key, %{
      publisher: "local",
      name: "pub-dash",
      is_public: true,
      org_id: "",
      project_id: "default"
    })

    on_exit(fn ->
      if original do
        Application.put_env(:cyfr, :components_path, original)
      else
        Application.delete_env(:cyfr, :components_path)
      end

      Arca.Cache.invalidate(vis_key)
      File.rm_rf!(base)
    end)

    %{private_dir: private_dir, public_dir: public_dir}
  end

  # ── Private tincture (requires auth) ─────────────────────────────

  describe "private tincture — unauthenticated" do
    test "returns 404 (indistinguishable from missing)", %{conn: conn} do
      conn = get(conn, "/t/local/auth-dash")
      assert conn.status == 404
    end
  end

  describe "private tincture — authenticated" do
    test "serves index.html with CSP headers", %{conn: conn} do
      conn =
        conn
        |> assign(:context, Sanctum.Context.local())
        |> assign(:current_user, %{id: "test-user"})

      conn =
        PrismWeb.TinctureController.index(conn, %{
          "publisher" => "local",
          "tincture_name" => "auth-dash"
        })

      assert conn.status == 200
      assert conn.resp_body =~ "Auth"

      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "connect-src 'self'"
      assert csp =~ "frame-ancestors 'self'"
    end

    test "injects base tag with signed token for private tincture", %{conn: conn} do
      conn =
        conn
        |> assign(:context, Sanctum.Context.local())
        |> assign(:current_user, %{id: "test-user"})

      conn =
        PrismWeb.TinctureController.index(conn, %{
          "publisher" => "local",
          "tincture_name" => "auth-dash"
        })

      assert conn.resp_body =~ ~r/<base href="\/t\/local\/auth-dash\/_s\/[^"]+\/">/
    end

    test "returns 404 for nonexistent tincture", %{conn: conn} do
      conn =
        conn
        |> assign(:context, Sanctum.Context.local())
        |> assign(:current_user, %{id: "test-user"})

      conn =
        PrismWeb.TinctureController.index(conn, %{
          "publisher" => "local",
          "tincture_name" => "no-such-tincture"
        })

      assert conn.status == 404
    end
  end

  describe "private tincture — token auth (shell iframe)" do
    test "serves index with valid _t token", %{conn: conn} do
      token = Phoenix.Token.sign(PrismWeb.Endpoint, "tincture_access", {"local", "auth-dash"})
      conn = get(conn, "/t/local/auth-dash?_t=#{token}")
      assert conn.status == 200
      assert conn.resp_body =~ "Auth"
    end

    test "returns 404 with invalid _t token", %{conn: conn} do
      conn = get(conn, "/t/local/auth-dash?_t=garbage")
      assert conn.status == 404
    end

    test "returns 404 with wrong-scope _t token", %{conn: conn} do
      token = Phoenix.Token.sign(PrismWeb.Endpoint, "tincture_access", {"local", "pub-dash"})
      conn = get(conn, "/t/local/auth-dash?_t=#{token}")
      assert conn.status == 404
    end
  end

  # ── Public tincture (no auth needed) ─────────────────────────────

  describe "public tincture — unauthenticated" do
    test "serves index.html without authentication", %{conn: conn} do
      conn = get(conn, "/t/local/pub-dash")
      assert conn.status == 200
      assert conn.resp_body =~ "Public"
    end

    test "sets CSP header with connect-src 'self'", %{conn: conn} do
      conn = get(conn, "/t/local/pub-dash")
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "connect-src 'self'"
    end

    test "injects plain base tag (no token) for public tincture", %{conn: conn} do
      conn = get(conn, "/t/local/pub-dash")
      assert conn.resp_body =~ ~s(<base href="/t/local/pub-dash/">)
      refute conn.resp_body =~ "_s/"
    end

    test "returns 404 for nonexistent tincture (indistinguishable from private)", %{conn: conn} do
      conn = get(conn, "/t/local/nonexistent")
      assert conn.status == 404
    end
  end

  # ── Assets (no auth required) ────────────────────────────────────

  describe "assets — public tinctures" do
    test "serves public tincture assets with CORS header", %{conn: conn} do
      conn = get(conn, "/t/local/pub-dash/style.css")
      assert conn.status == 200
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=3600"]
    end

    test "returns 404 for asset requests for unknown tincture", %{conn: conn} do
      conn = get(conn, "/t/local/no-such-tincture/app.js")
      assert conn.status == 404
    end

    test "blocks data.db for public tincture", %{conn: conn} do
      conn = get(conn, "/t/local/pub-dash/data.db")
      assert conn.status == 404
    end
  end

  describe "assets — private tinctures (no token)" do
    test "returns 404 for private tincture assets without token", %{conn: conn} do
      conn = get(conn, "/t/local/auth-dash/app.js")
      assert conn.status == 404
    end

    test "returns 404 for private tincture data.db", %{conn: conn} do
      conn = get(conn, "/t/local/auth-dash/data.db")
      assert conn.status == 404
    end
  end

  describe "assets — private tinctures (signed token)" do
    test "serves private tincture assets with valid token", %{conn: conn} do
      token = Phoenix.Token.sign(PrismWeb.Endpoint, "tincture_access", {"local", "auth-dash"})
      conn = get(conn, "/t/local/auth-dash/_s/#{token}/app.js")
      assert conn.status == 200
      assert conn.resp_body =~ "auth app"
      # CORS required for sandboxed iframes (opaque origin)
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      # Cache stays private — token-bearing URLs shouldn't be proxy-cached
      assert get_resp_header(conn, "cache-control") == ["private, max-age=3600"]
    end

    test "returns 404 for invalid token", %{conn: conn} do
      conn = get(conn, "/t/local/auth-dash/_s/garbage_token/app.js")
      assert conn.status == 404
    end

    test "returns 404 for token scoped to different tincture", %{conn: conn} do
      token = Phoenix.Token.sign(PrismWeb.Endpoint, "tincture_access", {"local", "pub-dash"})
      conn = get(conn, "/t/local/auth-dash/_s/#{token}/app.js")
      assert conn.status == 404
    end

    test "returns 404 for token with wrong publisher", %{conn: conn} do
      token = Phoenix.Token.sign(PrismWeb.Endpoint, "tincture_access", {"evil", "auth-dash"})
      conn = get(conn, "/t/local/auth-dash/_s/#{token}/app.js")
      assert conn.status == 404
    end

    test "blocks data.db even with valid token", %{conn: conn} do
      token = Phoenix.Token.sign(PrismWeb.Endpoint, "tincture_access", {"local", "auth-dash"})
      conn = get(conn, "/t/local/auth-dash/_s/#{token}/data.db")
      assert conn.status == 404
    end
  end

  # ── Query endpoint (public tinctures only) ───────────────────────

  describe "GET /t/:publisher/:tincture_name/q/:query_name" do
    test "executes a declared query", %{conn: conn} do
      conn = get(conn, "/t/local/pub-dash/q/all_items")
      assert conn.status == 200

      body = json_response(conn, 200)
      assert body["query"] == "all_items"
      assert length(body["data"]) == 2
    end

    test "returns 404 for undeclared query", %{conn: conn} do
      conn = get(conn, "/t/local/pub-dash/q/nonexistent")
      body = json_response(conn, 404)
      assert body["error"] == "Not Found"
    end

    test "returns 404 for nonexistent tincture", %{conn: conn} do
      conn = get(conn, "/t/local/no-such/q/test")
      body = json_response(conn, 404)
      assert body["error"] == "Not Found"
    end

    test "returns 404 for private tincture query", %{conn: conn} do
      conn = get(conn, "/t/local/auth-dash/q/test")
      body = json_response(conn, 404)
      assert body["error"] == "Not Found"
    end
  end
end
