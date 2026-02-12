defmodule EmissaryWeb.Plugs.MCPSessionTest do
  @moduledoc """
  Tests for the MCP session validation plug.

  Verifies auth provider integration and context propagation.
  """
  use EmissaryWeb.ConnCase

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
      %Sanctum.User{
        id: "test_user_123",
        email: "test@example.com",
        provider: "test",
        permissions: [:read, :write]
      }
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
          %Sanctum.User{
            id: "bearer_user",
            email: "bearer@example.com",
            provider: "bearer",
            permissions: [:admin]
          }

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
      ctx = Context.local()
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
      ctx = Context.local()
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
      user = %Sanctum.User{
        id: "hydrate_user",
        email: "hydrate@example.com",
        provider: "test",
        permissions: [:read]
      }

      {:ok, session} = Sanctum.Session.create(user)
      token = session.token

      # The ETS (in-memory) session does NOT exist for this token,
      # so the plug will hit the hydration path via Sanctum.Session.get_user
      conn =
        conn
        |> put_req_header("mcp-session-id", token)
        |> MCPSession.call([])

      # Hydration should succeed
      refute conn.halted
      assert conn.assigns[:mcp_context].user_id == "hydrate_user"
      assert conn.assigns[:mcp_session] != nil

      # Verify the session was refreshed (expires_at extended)
      {:ok, refreshed} = Sanctum.Session.get_user(token)
      assert refreshed.id == "hydrate_user"

      # Clean up
      Sanctum.Session.destroy(token)
    end
  end

  describe "call/2 - context creation with no auth provider" do
    setup do
      # Store original config
      original = Application.get_env(:sanctum, :auth_provider)
      Application.delete_env(:sanctum, :auth_provider)

      on_exit(fn ->
        if original do
          Application.put_env(:sanctum, :auth_provider, original)
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
      original = Application.get_env(:sanctum, :auth_provider)

      Application.put_env(:sanctum, :auth_provider, __MODULE__.TestAuthProvider)

      on_exit(fn ->
        if original do
          Application.put_env(:sanctum, :auth_provider, original)
        else
          Application.delete_env(:sanctum, :auth_provider)
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
      assert ctx.scope == :personal
    end
  end

  describe "call/2 - context creation with nil user from auth provider" do
    setup do
      # Store original config
      original = Application.get_env(:sanctum, :auth_provider)

      Application.put_env(:sanctum, :auth_provider, __MODULE__.NilAuthProvider)

      on_exit(fn ->
        if original do
          Application.put_env(:sanctum, :auth_provider, original)
        else
          Application.delete_env(:sanctum, :auth_provider)
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
      original = Application.get_env(:sanctum, :auth_provider)

      Application.put_env(:sanctum, :auth_provider, __MODULE__.BearerAuthProvider)

      on_exit(fn ->
        if original do
          Application.put_env(:sanctum, :auth_provider, original)
        else
          Application.delete_env(:sanctum, :auth_provider)
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
      test_dir = Path.join(System.tmp_dir!(), "cyfr_api_key_mcp_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(test_dir)

      # Store original configs
      original_base_path = Application.get_env(:arca, :base_path)
      original_auth = Application.get_env(:sanctum, :auth_provider)

      Application.put_env(:arca, :base_path, test_dir)
      # Use TestAuthProvider so we can test API key auth path independently
      Application.put_env(:sanctum, :auth_provider, __MODULE__.TestAuthProvider)

      # Create a test API key
      ctx = Context.local()
      {:ok, key_result} = Sanctum.ApiKey.create(ctx, %{
        name: "test-mcp-key",
        scope: ["execution", "read"],
        type: :public
      })

      on_exit(fn ->
        File.rm_rf!(test_dir)
        if original_base_path do
          Application.put_env(:arca, :base_path, original_base_path)
        else
          Application.delete_env(:arca, :base_path)
        end
        if original_auth do
          Application.put_env(:sanctum, :auth_provider, original_auth)
        else
          Application.delete_env(:sanctum, :auth_provider)
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
      assert ctx.api_key_type == :public
      # Permissions are converted to atoms via safe_to_permission_atom
      assert MapSet.member?(ctx.permissions, :execution)
      assert MapSet.member?(ctx.permissions, :read)
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
      ctx = Context.local()
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
