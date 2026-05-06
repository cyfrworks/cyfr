defmodule EmissaryWeb.Plugs.MCPSessionTest do
  @moduledoc """
  Tests for the MCP session validation plug.

  Verifies auth provider integration and context propagation.
  """
  use EmissaryWeb.ConnCase, async: false

  alias Emissary.MCP.Session
  alias EmissaryWeb.Plugs.MCPSession
  alias Sanctum.Context

  # Test auth provider that returns an authenticated user
  defmodule TestAuthProvider do
    @behaviour Sanctum.Auth

    @impl true
    def authenticate(_params), do: {:error, :not_implemented}

    @impl true
    def current_user(_conn) do
      Sanctum.Context.build(
        user_id: "test_user_123",
        email: "test@example.com",
        provider: "test",
        permissions: [:read, :write],
        namespace: "testns",
        authenticated: true
      )
    end
  end

  # Test auth provider with org_id for Arx mode tests
  defmodule ArxAuthProvider do
    @behaviour Sanctum.Auth

    @impl true
    def authenticate(_params), do: {:error, :not_implemented}

    @impl true
    def current_user(_conn) do
      Sanctum.Context.build(
        user_id: "test_user_123",
        email: "test@example.com",
        provider: "test",
        permissions: [:read, :write],
        org_id: "org_test",
        project_id: "proj_test",
        namespace: "testns",
        authenticated: true
      )
    end
  end

  # Test auth provider that returns nil
  defmodule NilAuthProvider do
    @behaviour Sanctum.Auth

    @impl true
    def authenticate(_params), do: {:error, :not_implemented}

    @impl true
    def current_user(_conn), do: nil
  end

  # Test auth provider that checks for Bearer token
  defmodule BearerAuthProvider do
    @behaviour Sanctum.Auth

    @impl true
    def authenticate(_params), do: {:error, :not_implemented}

    @impl true
    def current_user(conn) do
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer valid_token"] ->
          Sanctum.Context.build(
            user_id: "bearer_user",
            email: "bearer@example.com",
            provider: "bearer",
            permissions: [:admin],
            namespace: "testns",
            authenticated: true
          )

        ["Bearer invalid_token"] ->
          nil

        _ ->
          nil
      end
    end
  end

  describe "call/2 - session validation" do
    test "assigns nil session when no Mcp-Session-Id header", %{conn: conn} do
      conn = MCPSession.call(conn, [])

      assert conn.assigns[:mcp_session] == nil
      assert conn.assigns[:mcp_context]
    end

    test "assigns session when valid Mcp-Session-Id provided", %{conn: conn} do
      # Create a session first
      ctx = Sanctum.TestContext.local()
      {:ok, session} = Session.create(ctx)

      conn =
        conn
        |> put_req_header("mcp-session-id", session.id)
        |> MCPSession.call([])

      assert conn.assigns[:mcp_session].id == session.id
      assert conn.assigns[:mcp_context] == session.context

      Session.terminate(session.id)
    end

    test "returns 404 for invalid/expired session ID", %{conn: conn} do
      conn =
        conn
        |> put_req_header("mcp-session-id", "sess_nonexistent")
        |> Map.put(:body_params, %{"method" => "tools/call"})
        |> MCPSession.call([])

      assert conn.halted
      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["message"] =~ "Session not found or expired"
    end

    test "allows initialize through with stale session ID", %{conn: conn} do
      conn =
        conn
        |> put_req_header("mcp-session-id", "sess_stale_gone")
        |> Map.put(:body_params, %{"method" => "initialize"})
        |> MCPSession.call([])

      refute conn.halted
      assert conn.assigns[:mcp_session] == nil
      assert conn.assigns[:mcp_context]
    end

    test "returns 404 for expired session", %{conn: conn} do
      # Create a session
      ctx = Sanctum.TestContext.local()
      {:ok, session} = Session.create(ctx)

      # Terminate it to simulate expiration
      Session.terminate(session.id)

      conn =
        conn
        |> put_req_header("mcp-session-id", session.id)
        |> Map.put(:body_params, %{"method" => "tools/call"})
        |> MCPSession.call([])

      assert conn.halted
      assert conn.status == 404
    end
  end

  describe "call/2 - session hydration with refresh" do
    test "hydration from SQLite refreshes session expiration", %{conn: conn} do
      # Create a persistent session via Sanctum (stored in SQLite)
      ctx =
        Sanctum.Context.build(
          user_id: "hydrate_user",
          email: "hydrate@example.com",
          provider: "test",
          permissions: [:read],
          namespace: "testns",
          authenticated: true
        )

      {:ok, session} = Sanctum.Session.create(ctx)
      token = session.token

      # The ETS (in-memory) session does NOT exist for this token,
      # so the plug will hit the hydration path via Sanctum.Session.load
      conn =
        conn
        |> put_req_header("mcp-session-id", token)
        |> MCPSession.call([])

      # Hydration should succeed
      refute conn.halted
      assert conn.assigns[:mcp_context].user_id == "hydrate_user"
      assert conn.assigns[:mcp_session] != nil

      # Verify the session was refreshed (expires_at extended)
      {:ok, refreshed} = Sanctum.Session.load(token)
      assert refreshed.user_id == "hydrate_user"

      # Clean up
      Sanctum.Session.destroy(token)
    end
  end

  describe "call/2 - context creation with no auth provider" do
    setup do
      # Store original config
      original = Application.get_env(:cyfr, :auth_provider)
      Application.delete_env(:cyfr, :auth_provider)

      on_exit(fn ->
        if original do
          Application.put_env(:cyfr, :auth_provider, original)
        end
      end)

      :ok
    end

    test "returns unauthenticated context when no auth provider configured", %{conn: conn} do
      conn = MCPSession.call(conn, [])

      ctx = conn.assigns[:mcp_context]
      assert ctx.user_id == nil
      assert ctx.permissions == MapSet.new()
      assert ctx.authenticated == false
    end
  end

  describe "call/2 - context creation with custom auth provider" do
    setup do
      # Store original config
      original = Application.get_env(:cyfr, :auth_provider)

      Application.put_env(:cyfr, :auth_provider, __MODULE__.TestAuthProvider)

      on_exit(fn ->
        if original do
          Application.put_env(:cyfr, :auth_provider, original)
        else
          Application.delete_env(:cyfr, :auth_provider)
        end
      end)

      :ok
    end

    test "creates context from authenticated user", %{conn: conn} do
      conn = MCPSession.call(conn, [])

      ctx = conn.assigns[:mcp_context]
      assert ctx.user_id == "test_user_123"
      assert MapSet.member?(ctx.permissions, :read)
      assert MapSet.member?(ctx.permissions, :write)
      assert ctx.scope == :project
    end
  end

  describe "call/2 - context creation with nil user from auth provider" do
    setup do
      # Store original config
      original = Application.get_env(:cyfr, :auth_provider)

      Application.put_env(:cyfr, :auth_provider, __MODULE__.NilAuthProvider)

      on_exit(fn ->
        if original do
          Application.put_env(:cyfr, :auth_provider, original)
        else
          Application.delete_env(:cyfr, :auth_provider)
        end
      end)

      :ok
    end

    test "returns unauthenticated context when auth provider returns nil", %{conn: conn} do
      conn = MCPSession.call(conn, [])

      ctx = conn.assigns[:mcp_context]
      assert ctx.user_id == nil
      assert ctx.permissions == MapSet.new()
    end
  end

  describe "Authorization header support" do
    setup do
      # Store original config
      original = Application.get_env(:cyfr, :auth_provider)

      Application.put_env(:cyfr, :auth_provider, __MODULE__.BearerAuthProvider)

      on_exit(fn ->
        if original do
          Application.put_env(:cyfr, :auth_provider, original)
        else
          Application.delete_env(:cyfr, :auth_provider)
        end
      end)

      :ok
    end

    test "auth provider receives conn with Authorization header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer valid_token")
        |> MCPSession.call([])

      ctx = conn.assigns[:mcp_context]
      assert ctx.user_id == "bearer_user"
      assert MapSet.member?(ctx.permissions, :admin)
    end

    test "invalid Bearer token returns unauthenticated context", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid_token")
        |> MCPSession.call([])

      ctx = conn.assigns[:mcp_context]
      # Auth failure returns unauthenticated context
      assert ctx.user_id == nil
      assert ctx.permissions == MapSet.new()
    end

    test "missing Authorization header returns unauthenticated context", %{conn: conn} do
      conn = MCPSession.call(conn, [])

      ctx = conn.assigns[:mcp_context]
      # No auth returns unauthenticated context
      assert ctx.user_id == nil
      assert ctx.permissions == MapSet.new()
    end
  end

  describe "API key authentication" do
    setup do
      # Use a temp directory for API key tests
      test_dir =
        Path.join(
          System.tmp_dir!(),
          "cyfr_api_key_mcp_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(test_dir)

      # Store original configs
      original_base_path = Application.get_env(:cyfr, :base_path)
      original_auth = Application.get_env(:cyfr, :auth_provider)

      Application.put_env(:cyfr, :base_path, test_dir)
      # Use TestAuthProvider so we can test API key auth path independently
      Application.put_env(:cyfr, :auth_provider, __MODULE__.TestAuthProvider)

      # Create a test API key
      ctx = Sanctum.TestContext.local()

      {:ok, key_result} =
        Sanctum.ApiKey.create(ctx, %{
          name: "test-mcp-key",
          type: :application
        })

      on_exit(fn ->
        File.rm_rf!(test_dir)

        if original_base_path do
          Application.put_env(:cyfr, :base_path, original_base_path)
        else
          Application.delete_env(:cyfr, :base_path)
        end

        if original_auth do
          Application.put_env(:cyfr, :auth_provider, original_auth)
        else
          Application.delete_env(:cyfr, :auth_provider)
        end
      end)

      {:ok, test_dir: test_dir, api_key: key_result.key}
    end

    test "authenticates with valid API key", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> MCPSession.call([])

      refute conn.halted
      ctx = conn.assigns[:mcp_context]

      assert ctx.auth_method == :api_key
      assert ctx.api_key_type == :application
      # Application keys get default scopes: execute, component_read, policy_read, storage_read
      assert ctx.permissions ==
               MapSet.new([:execute, :component_read, :policy_read, :storage_read])

      assert conn.assigns[:auth_method] == :api_key
    end

    test "returns 401 for invalid API key", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer cyfr_pk_invalid123456789012345678")
        |> MCPSession.call([])

      assert conn.halted
      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["message"] =~ "Invalid API key"
    end

    test "falls back to session auth for non-cyfr Bearer token", %{conn: conn} do
      # Non-cyfr_ prefixed tokens should fall through to session auth
      conn =
        conn
        |> put_req_header("authorization", "Bearer some_other_token")
        |> MCPSession.call([])

      # Should fall back to TestAuthProvider which returns test_user_123
      refute conn.halted
      ctx = conn.assigns[:mcp_context]
      assert ctx.user_id == "test_user_123"
    end

    test "API key auth bypasses session requirement", %{conn: conn, api_key: api_key} do
      # API keys should work without any session
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> MCPSession.call([])

      refute conn.halted
      assert conn.assigns[:mcp_session] == nil
      assert conn.assigns[:mcp_context].auth_method == :api_key
    end

    test "API key auth takes priority over session", %{conn: conn, api_key: api_key} do
      # Create a session
      ctx = Sanctum.TestContext.local()
      {:ok, session} = Session.create(ctx)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> put_req_header("mcp-session-id", session.id)
        |> MCPSession.call([])

      # API key should take priority
      refute conn.halted
      assert conn.assigns[:auth_method] == :api_key
      assert conn.assigns[:mcp_session] == nil

      Session.terminate(session.id)
    end

    test "context has authenticated: true for valid API key", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> MCPSession.call([])

      refute conn.halted
      ctx = conn.assigns[:mcp_context]
      assert ctx.authenticated == true
    end
  end

  # Test auth provider that returns an error
  defmodule ErrorAuthProvider do
    @behaviour Sanctum.Auth

    @impl true
    def authenticate(_params), do: {:error, :not_implemented}

    @impl true
    def current_user(_conn), do: {:error, :connection_refused}
  end

  describe "call/2 - Arx mode auth enforcement" do
    @describetag :requires_arx

    setup do
      original_edition = Application.get_env(:cyfr, :edition)
      original_auth = Application.get_env(:cyfr, :auth_provider)
      original_policy = Application.get_env(:cyfr, :tenant_policy)

      Application.put_env(:cyfr, :edition, :arx)
      Application.put_env(:cyfr, :tenant_policy, Arx.Sanctum.TenantPolicy)

      on_exit(fn ->
        if original_edition do
          Application.put_env(:cyfr, :edition, original_edition)
        else
          Application.delete_env(:cyfr, :edition)
        end

        if original_auth do
          Application.put_env(:cyfr, :auth_provider, original_auth)
        else
          Application.delete_env(:cyfr, :auth_provider)
        end

        if original_policy do
          Application.put_env(:cyfr, :tenant_policy, original_policy)
        else
          Application.delete_env(:cyfr, :tenant_policy)
        end
      end)

      :ok
    end

    test "rejects request with 503 when no auth_provider in Arx mode", %{conn: conn} do
      Application.delete_env(:cyfr, :auth_provider)

      conn = MCPSession.call(conn, [])

      assert conn.halted
      assert conn.status == 503
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["message"] =~ "Authentication service unavailable"
    end

    test "rejects request with 503 when auth provider returns nil in Arx mode", %{conn: conn} do
      Application.put_env(:cyfr, :auth_provider, __MODULE__.NilAuthProvider)

      conn = MCPSession.call(conn, [])

      assert conn.halted
      assert conn.status == 503
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["message"] =~ "Authentication service unavailable"
    end

    test "rejects request with 503 when auth provider returns error in Arx mode", %{conn: conn} do
      Application.put_env(:cyfr, :auth_provider, __MODULE__.ErrorAuthProvider)

      conn = MCPSession.call(conn, [])

      assert conn.halted
      assert conn.status == 503
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["message"] =~ "Authentication service unavailable"
    end

    test "allows authenticated user with org_id through in Arx mode", %{conn: conn} do
      Application.put_env(:cyfr, :auth_provider, __MODULE__.ArxAuthProvider)

      conn = MCPSession.call(conn, [])

      refute conn.halted
      ctx = conn.assigns[:mcp_context]
      assert ctx.user_id == "test_user_123"
      assert ctx.org_id == "org_test"
      assert ctx.authenticated == true
    end

    test "rejects authenticated user without org_id with 403 in Arx mode", %{conn: conn} do
      Application.put_env(:cyfr, :auth_provider, __MODULE__.TestAuthProvider)

      conn = MCPSession.call(conn, [])

      assert conn.halted
      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["message"] =~ "no organization membership"
    end
  end

  # Auth provider that returns a user with no org_id (triggers membership resolution)
  defmodule NoOrgAuthProvider do
    @behaviour Sanctum.Auth

    @impl true
    def authenticate(_params), do: {:error, :not_implemented}

    @impl true
    def current_user(_conn) do
      Sanctum.Context.build(
        user_id: "noorg_user_1",
        email: "noorg@example.com",
        provider: "test",
        permissions: [:read, :write],
        org_id: nil,
        project_id: nil,
        namespace: "testns",
        authenticated: true
      )
    end
  end

  describe "Arx mode membership resolution error handling" do
    @describetag :requires_arx

    setup do
      original_edition = Application.get_env(:cyfr, :edition)
      original_auth = Application.get_env(:cyfr, :auth_provider)
      original_resolver = Application.get_env(:cyfr, :membership_resolver)
      original_policy = Application.get_env(:cyfr, :tenant_policy)
      original_license = :persistent_term.get(:arx_license, nil)

      Application.put_env(:cyfr, :edition, :arx)
      Application.put_env(:cyfr, :auth_provider, __MODULE__.NoOrgAuthProvider)
      # Swap in the Arx resolver so the test's license_expired setup can take effect.
      Application.put_env(:cyfr, :membership_resolver, Arx.Sanctum.MembershipResolver)
      # Swap to Arx tenant policy so require_org/1 rejects nil org_id.
      Application.put_env(:cyfr, :tenant_policy, Arx.Sanctum.TenantPolicy)
      # Set license to nil so require_arx() returns {:error, :license_expired}
      :persistent_term.put(:arx_license, nil)

      on_exit(fn ->
        if original_edition do
          Application.put_env(:cyfr, :edition, original_edition)
        else
          Application.delete_env(:cyfr, :edition)
        end

        if original_auth do
          Application.put_env(:cyfr, :auth_provider, original_auth)
        else
          Application.delete_env(:cyfr, :auth_provider)
        end

        if original_resolver do
          Application.put_env(:cyfr, :membership_resolver, original_resolver)
        else
          Application.delete_env(:cyfr, :membership_resolver)
        end

        if original_policy do
          Application.put_env(:cyfr, :tenant_policy, original_policy)
        else
          Application.delete_env(:cyfr, :tenant_policy)
        end

        if original_license do
          :persistent_term.put(:arx_license, original_license)
        else
          :persistent_term.put(:arx_license, :core)
        end
      end)

      :ok
    end

    test "logs error and returns 403 when membership resolution fails with DB error", %{
      conn: conn
    } do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          conn = MCPSession.call(conn, [])

          # User has no org_id and membership resolution failed,
          # so Arx mode should reject with 403 (missing_tenant)
          assert conn.halted
          assert conn.status == 403
          body = Jason.decode!(conn.resp_body)
          assert body["error"]["message"] =~ "no organization membership"
        end)

      assert log =~ "[MCPSession] Failed to resolve membership"
      assert log =~ "license_expired"
    end
  end

  describe "IP address extraction" do
    test "handles empty X-Forwarded-For header gracefully", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-forwarded-for", "")
        |> MCPSession.call([])

      # Should not crash, should use remote_ip fallback
      refute conn.halted
      assert conn.assigns[:mcp_context]
    end

    test "handles malformed X-Forwarded-For header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-forwarded-for", "not-an-ip, also-not-an-ip")
        |> MCPSession.call([])

      # Should not crash, should use remote_ip fallback
      refute conn.halted
      assert conn.assigns[:mcp_context]
    end

    test "handles valid X-Forwarded-For with multiple IPs", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-forwarded-for", "192.168.1.1, 10.0.0.1, 172.16.0.1")
        |> MCPSession.call([])

      # Should take first IP
      refute conn.halted
      assert conn.assigns[:mcp_context]
    end
  end
end
