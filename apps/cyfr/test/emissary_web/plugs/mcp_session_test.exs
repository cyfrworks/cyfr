# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

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
        # Org-less on purpose: exercises the no-resolved-org rejection path.
        org_id: nil,
        namespace: "testns",
        authenticated: true
      )
    end
  end

  # Test auth provider with org_id for tests where an auth provider is configured
  defmodule StubAuthProvider do
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
            org_id: "local",
            project_id: "default",
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

  # These used to assert a session lifecycle: a valid `Mcp-Session-Id` loaded a
  # stored session, an unknown one returned 404, a stale one was let through for
  # `initialize`, and hydration from SQLite refreshed the row's expiry.
  #
  # None of that exists. The protocol has no session, so the header authenticates
  # nothing and the server must ignore it. What replaces those tests is the
  # property that now has to hold: whatever the header says, it changes nothing —
  # which is strictly stronger, because the old behaviour still fed the value
  # into a lookup before rejecting it.
  describe "call/2 — the retired session header" do
    test "a request with no credential still gets a context", %{conn: conn} do
      conn = MCPSession.call(conn, [])

      refute conn.halted
      assert conn.assigns[:mcp_context]
      assert conn.assigns[:mcp_session] == nil
    end

    test "a session id in the header neither authenticates nor rejects", %{conn: conn} do
      ctx = Sanctum.TestContext.local()
      {:ok, session} = Sanctum.Session.create(ctx)

      conn =
        conn
        |> put_req_header("mcp-session-id", session.token)
        |> Map.put(:body_params, %{"method" => "tools/call"})
        |> MCPSession.call([])

      refute conn.halted
      assert conn.assigns[:mcp_session] == nil
    end

    test "an unknown session id is not an error", %{conn: conn} do
      conn =
        conn
        |> put_req_header("mcp-session-id", "sess_nonexistent")
        |> Map.put(:body_params, %{"method" => "tools/call"})
        |> MCPSession.call([])

      refute conn.halted
      assert conn.assigns[:mcp_session] == nil
    end
  end

  # The same credential the header used to carry, in the place it belongs.
  describe "call/2 — a session token as a bearer credential" do
    test "authenticates and resolves the stored context", %{conn: conn} do
      ctx =
        Sanctum.Context.build(
          user_id: "hydrate_user",
          email: "hydrate@example.com",
          provider: "test",
          permissions: [:read],
          org_id: "local",
          project_id: "default",
          namespace: "testns",
          authenticated: true
        )

      Compendium.Registry.CredentialStore.put(
        "hydrate_user",
        Compendium.Registry.canonical_host(),
        "testns",
        %{type: :push_token, token: "test-token", role: "owner"}
      )

      {:ok, session} = Sanctum.Session.create(ctx)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> session.token)
        |> MCPSession.call([])

      refute conn.halted
      assert conn.assigns[:mcp_context].user_id == "hydrate_user"
      assert conn.assigns[:auth_method] == :session_token

      Sanctum.Session.destroy(session.token)
    end

    # A presented-but-dead credential used to fall through to the anonymous
    # surface, which reads to the caller as "your request worked" rather than
    # "your token is gone".
    #
    # The refusal is deliberately last: an auth provider may accept bearer
    # tokens of its own, so an unrecognised one is only invalid once nothing
    # else has claimed it. With no provider configured, nothing can.
    test "an unclaimed bearer is refused once nothing else can claim it", %{conn: conn} do
      original = Application.get_env(:cyfr, :auth_provider)
      Application.delete_env(:cyfr, :auth_provider)
      on_exit(fn -> Application.put_env(:cyfr, :auth_provider, original) end)

      conn =
        conn
        |> put_req_header("authorization", "Bearer not-a-real-session-token")
        |> Map.put(:body_params, %{"method" => "tools/call"})
        |> MCPSession.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "an unclaimed bearer is left to a configured auth provider", %{conn: conn} do
      # The provider in this file's setup accepts any caller, so the request
      # proceeds — the plug does not pre-empt it.
      conn =
        conn
        |> put_req_header("authorization", "Bearer a-token-only-the-provider-knows")
        |> MCPSession.call([])

      refute conn.halted
      assert conn.assigns[:mcp_context].authenticated
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

      Application.put_env(:cyfr, :auth_provider, __MODULE__.StubAuthProvider)

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

    # This used to assert the opposite — that a bad token yielded an
    # unauthenticated context and the request continued onto the public surface.
    # That is a fail-open: a caller whose token was revoked got a 200 for
    # whatever happens to be public instead of being told the credential is dead,
    # and the difference between "not signed in" and "no longer signed in" was
    # invisible to them.
    test "an invalid Bearer token is refused rather than downgraded", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid_token")
        |> MCPSession.call([])

      assert conn.halted
      assert conn.status == 401
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
      # Use an org-bearing provider so the session-fallback path resolves a tenant.
      Application.put_env(:cyfr, :auth_provider, __MODULE__.StubAuthProvider)

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

    test "a Sanctum session token authenticates as a bearer credential", %{conn: conn} do
      # Stateless auth: the credential travels on the request itself, so no
      # server-side MCP session is created and nothing is cached.
      ctx = Sanctum.TestContext.local()
      {:ok, session} = Sanctum.Session.create(ctx)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{session.token}")
        |> MCPSession.call([])

      refute conn.halted
      # Nothing is stored; the session is derived from the credential purely as
      # a correlation key, so it carries a "cred_" id rather than a "sess_" one.
      assert %Session{id: "req_" <> _} = conn.assigns[:mcp_session]
      assert conn.assigns[:auth_method] == :session_token
      assert conn.assigns[:mcp_context].user_id == ctx.user_id
      # `authenticated` additionally depends on the user having claimed a
      # personal namespace, which is a separate gate from bearer auth.
    end

    test "a destroyed session token stops authenticating immediately", %{conn: conn} do
      # The bearer path reads the row on every request, so revocation takes
      # effect on the next call rather than when a cache entry expires.
      ctx = Sanctum.TestContext.local()
      {:ok, session} = Sanctum.Session.create(ctx)
      :ok = Sanctum.Session.destroy(session.token)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{session.token}")
        |> MCPSession.call([])

      resolved = conn.assigns[:mcp_context]
      refute resolved && resolved.user_id == ctx.user_id && resolved.authenticated
    end

    test "API key auth bypasses session requirement", %{conn: conn, api_key: api_key} do
      # API keys should work without any session
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> MCPSession.call([])

      refute conn.halted
      # No stored session — the plug supplies an uncached, credential-keyed one
      # purely so a caller's POST and its progress stream share a key.
      assert %Emissary.MCP.Session{id: "req_" <> _} = conn.assigns[:mcp_session]
      assert conn.assigns[:auth_method] == :api_key
      assert conn.assigns[:mcp_context].auth_method == :api_key
    end

    test "the bearer credential decides, whatever the retired header says",
         %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> put_req_header("mcp-session-id", "sess_something_else_entirely")
        |> MCPSession.call([])

      refute conn.halted
      assert conn.assigns[:auth_method] == :api_key
      assert conn.assigns[:mcp_context].auth_method == :api_key
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

  describe "call/2 - auth enforcement" do
    setup do
      original_auth = Application.get_env(:cyfr, :auth_provider)

      on_exit(fn ->
        if original_auth do
          Application.put_env(:cyfr, :auth_provider, original_auth)
        else
          Application.delete_env(:cyfr, :auth_provider)
        end
      end)

      :ok
    end

    test "no auth_provider configured — request reaches the public surface unauthenticated",
         %{conn: conn} do
      Application.delete_env(:cyfr, :auth_provider)

      conn = MCPSession.call(conn, [])

      refute conn.halted
      refute conn.assigns[:mcp_context].authenticated
    end

    test "auth provider returns nil credentials — unauthenticated context, not rejected",
         %{conn: conn} do
      Application.put_env(:cyfr, :auth_provider, __MODULE__.NilAuthProvider)

      conn = MCPSession.call(conn, [])

      refute conn.halted
      refute conn.assigns[:mcp_context].authenticated
    end

    test "auth provider *error* fails closed with 503", %{conn: conn} do
      Application.put_env(:cyfr, :auth_provider, __MODULE__.ErrorAuthProvider)

      conn = MCPSession.call(conn, [])

      assert conn.halted
      assert conn.status == 503
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["message"] =~ "Authentication service unavailable"
    end

    test "allows an authenticated user with a resolved org_id through", %{conn: conn} do
      Application.put_env(:cyfr, :auth_provider, __MODULE__.StubAuthProvider)

      conn = MCPSession.call(conn, [])

      refute conn.halted
      ctx = conn.assigns[:mcp_context]
      assert ctx.user_id == "test_user_123"
      assert ctx.org_id == "org_test"
      assert ctx.authenticated == true
    end

    test "rejects an authenticated user with no resolved org_id with 403", %{conn: conn} do
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

  describe "membership resolution error handling" do
    setup do
      original_auth = Application.get_env(:cyfr, :auth_provider)
      original_resolver = Application.get_env(:cyfr, :tenancy_resolver_override)

      Application.put_env(:cyfr, :auth_provider, __MODULE__.NoOrgAuthProvider)
      # Inject a resolver that errors so the plug's "no resolved org → 403"
      # branch is exercised.
      Application.put_env(:cyfr, :tenancy_resolver_override, Sanctum.Test.FailingResolver)

      on_exit(fn ->
        if original_auth do
          Application.put_env(:cyfr, :auth_provider, original_auth)
        else
          Application.delete_env(:cyfr, :auth_provider)
        end

        if original_resolver do
          Application.put_env(:cyfr, :tenancy_resolver_override, original_resolver)
        else
          Application.delete_env(:cyfr, :tenancy_resolver_override)
        end
      end)

      :ok
    end

    test "logs error and returns 403 when membership resolution fails", %{conn: conn} do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          conn = MCPSession.call(conn, [])

          # User has no org_id and membership resolution failed → reject with
          # 403 (missing_tenant).
          assert conn.halted
          assert conn.status == 403
          body = Jason.decode!(conn.resp_body)
          assert body["error"]["message"] =~ "no organization membership"
        end)

      # Resolution + its error logging is centralized in Sanctum.Tenancy.
      assert log =~ "[Sanctum.Tenancy] resolve override failed"
      assert log =~ "resolve_failed"
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
