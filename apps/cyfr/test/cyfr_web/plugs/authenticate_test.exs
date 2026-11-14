# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.AuthenticateTest do
  @moduledoc """
  Tests for the credential-resolution plug.

  Verifies bearer handling and context propagation.
  The MCP endpoint's own conformance rules are a separate plug and are
  exercised end-to-end through the pipeline in
  `Emissary.Web.MCPControllerTest`.
  """
  use CyfrWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias CyfrWeb.Plugs.Authenticate

  # The plug as a pipeline mounts it: its options through `init/1`.
  defp authenticate(conn, opts \\ []), do: Authenticate.call(conn, Authenticate.init(opts))

  # A person admitted by their account, their head cached here
  # (`Sanctum.TestContext.account!/1`) at the suite's directory, which this
  # CYFR cannot reach, on a public CYFR, which pauses a head it cannot
  # refresh past its bound, and a session of theirs. Answers its token.
  defp remote_session! do
    n = System.unique_integer([:positive])
    Prima.Test.Env.put_app_env(:sanctum, :access_mode, :public)

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|remote-bearer-#{n}",
        provider: "github",
        email: "remote-bearer#{n}@example.com",
        verified: true
      })

    athanor = Sanctum.Test.People.athanor!(user)

    {:ok, session} =
      Sanctum.TestContext.create_session(
        Sanctum.Context.build(
          user_id: user.id,
          athanor_id: athanor.id,
          provider: "passkey",
          permissions: Sanctum.Context.person_permissions(),
          auth_method: :oidc,
          authenticated: true
        )
      )

    %{
      user_id: user.id,
      identifier: Sanctum.TestContext.account!(user.id).identifier,
      token: session.token
    }
  end

  # Authenticate session tokens through the Authorization header.
  describe "call/2 — a session token as a bearer credential" do
    test "authenticates and resolves the stored context", %{conn: conn} do
      {:ok, user} =
        Sanctum.Test.People.linked(%{
          id: "test|https://test.example|hydrate_user",
          provider: "test",
          email: "hydrate@example.com",
          verified: true
        })

      {:ok, _} = Sanctum.Tenancy.Users.set_namespace(user, "testns")

      # From admission on the person is named by their own id, and a
      # restored session is revalidated against their own athanor.
      ctx =
        Sanctum.Context.build(
          user_id: user.id,
          email: "hydrate@example.com",
          provider: "test",
          permissions: [:read],
          athanor_id: Sanctum.Test.People.athanor!(user.id).id,
          namespace: "testns",
          authenticated: true
        )

      {:ok, session} = Sanctum.TestContext.create_session(ctx)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> session.token)
        |> authenticate()

      refute conn.halted
      assert conn.assigns[:context].user_id == user.id
      assert conn.assigns[:context].auth_method == :oidc

      Sanctum.Session.destroy(session.token)
    end

    # The establish memo bounds establishing, not validating: a context it
    # answers is revalidated against the stored session before admission.
    defp warm_memo! do
      original = Application.fetch_env(:sanctum, :caller_memo_ttl_ms)
      Application.put_env(:sanctum, :caller_memo_ttl_ms, 60_000)

      on_exit(fn ->
        Arca.Cache.delete_match({:established, :_, :_})

        case original do
          {:ok, value} -> Application.put_env(:sanctum, :caller_memo_ttl_ms, value)
          :error -> Application.delete_env(:sanctum, :caller_memo_ttl_ms)
        end
      end)

      ctx = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
      {:ok, session} = Sanctum.Session.create(ctx)
      assert {:ok, _} = Sanctum.Caller.establish(session.token, refresh: false)
      session
    end

    test "a session revoked behind a warm memo is refused, not admitted from the memo", %{
      conn: conn
    } do
      session = warm_memo!()

      # Revoked with nobody told: the memo still holds the context.
      hash = Sanctum.Session.token_hash(session.token)
      Arca.Repo.delete_all(from(s in Arca.Schemas.Session, where: s.token_hash == ^hash))
      assert {:ok, _} = Sanctum.Caller.establish(session.token, refresh: false)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> session.token)
        |> Map.put(:body_params, %{"method" => "tools/call"})
        |> authenticate()

      assert conn.halted
      assert conn.status == 401

      # Nothing is left to say what ended it: the sentence names every
      # case, never "expired" alone.
      assert Jason.decode!(conn.resp_body) == %{
               "code" => "unauthenticated",
               "message" =>
                 "This sign-in no longer stands: it expired or was signed out, or this device " <>
                   "or your access was removed. Sign in again; if you are refused, ask the " <>
                   "person who runs this CYFR."
             }
    end

    test "a session bearer the store cannot revalidate is a 503, never an admission", %{
      conn: conn
    } do
      session = warm_memo!()
      Arca.Repo.query!("ALTER TABLE sessions RENAME TO sessions_unavailable")

      # The memo still answers establish; the revalidation cannot be answered.
      assert {:ok, _} = Sanctum.Caller.establish(session.token, refresh: false)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> session.token)
        |> authenticate()

      assert conn.halted
      assert conn.status == 503
    end

    test "an account's session stands on its fresh head", %{conn: conn} do
      remote = remote_session!()

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> remote.token)
        |> authenticate()

      refute conn.halted
      assert conn.assigns[:context].user_id == remote.user_id
    end

    test "an account that could not be confirmed fresh is a 503 with its sentence",
         %{conn: conn} do
      remote = remote_session!()

      Arca.Repo.update_all(
        from(h in Arca.Schemas.DirectoryHead, where: h.identifier == ^remote.identifier),
        set: [verified_at: DateTime.add(DateTime.utc_now(), -400, :second)]
      )

      {conn, log} =
        ExUnit.CaptureLog.with_log(fn ->
          conn
          |> put_req_header("authorization", "Bearer " <> remote.token)
          |> Map.put(:body_params, %{"method" => "tools/call"})
          |> authenticate()
        end)

      assert log =~ "freshness bound"
      assert conn.halted
      assert conn.status == 503

      assert Jason.decode!(conn.resp_body) == %{
               "code" => "unavailable",
               "message" => Prima.Refusal.message(:identity_stale)
             }

      # A pause, never a dead credential: no challenge to sign in again, and
      # the session stands.
      assert get_resp_header(conn, "www-authenticate") == []
      hash = Sanctum.Session.token_hash(remote.token)
      assert Arca.Repo.exists?(from(s in Arca.Schemas.Session, where: s.token_hash == ^hash))
    end

    # A bearer no credential matches is refused, never served as an
    # anonymous caller.
    test "a bearer that is no session this server issued is refused", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-a-real-session-token")
        |> Map.put(:body_params, %{"method" => "tools/call"})
        |> authenticate()

      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "call/2 — the ConnCase's signed-in person" do
    test "a request with no credential gets an unauthenticated context", %{conn: conn} do
      conn = authenticate(conn)

      refute conn.halted
      ctx = conn.assigns[:context]
      assert ctx.user_id == nil
      assert ctx.permissions == MapSet.new()
      assert ctx.authenticated == false
    end

    test "the person is the test athanor's, by a session, with the person permissions" do
      conn = conn_for(%{async: false}) |> authenticate_as() |> authenticate()

      refute conn.halted
      ctx = conn.assigns.context
      assert ctx.user_id == Arca.Test.Actor.owner_id()
      assert ctx.athanor_id == Sanctum.TestContext.athanor_id()
      assert ctx.auth_method == :oidc
      assert is_binary(ctx.session_token_hash)
      assert Enum.sort(ctx.permissions) == Enum.sort(Sanctum.Context.person_permissions())
    end

    @tag auth: :person
    test "the case's conn carries a session's bearer only under `auth: :person`", %{conn: conn} do
      assert ["Bearer " <> token] = get_req_header(conn, "authorization")
      assert {:ok, ctx} = Sanctum.Caller.establish(token, refresh: false)
      assert ctx.user_id == Arca.Test.Actor.owner_id()

      assert get_req_header(conn_for(%{async: false, auth: :none}), "authorization") == []
      assert get_req_header(conn_for(%{async: false}), "authorization") == []
    end

    test "`auth` tagged on an async test raises" do
      assert_raise ArgumentError, ~r/async test/, fn ->
        conn_for(%{async: true, auth: :person})
      end
    end

    test "an unknown `auth` value raises" do
      assert_raise ArgumentError, ~r/unknown `auth` tag :admin/, fn ->
        conn_for(%{async: false, auth: :admin})
      end
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
      original_base_path = Application.get_env(:arca, :base_path)

      Application.put_env(:arca, :base_path, test_dir)

      # Create a test API key
      ctx = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())

      {:ok, key_result} =
        Sanctum.TestContext.create_key(ctx, %{
          name: "test-mcp-key",
          type: :application
        })

      on_exit(fn ->
        File.rm_rf!(test_dir)

        if original_base_path do
          Application.put_env(:arca, :base_path, original_base_path)
        else
          Application.delete_env(:arca, :base_path)
        end
      end)

      {:ok, test_dir: test_dir, api_key: key_result.api_key}
    end

    test "a key whose creator names nobody is refused at the plug", %{
      conn: conn,
      api_key: api_key
    } do
      import Ecto.Query
      hash = :crypto.hash(:sha256, api_key)

      for creator <- ["nobody", "usr_nobody", nil] do
        {1, _} =
          Arca.Repo.update_all(from(k in Arca.Schemas.ApiKey, where: k.key_hash == ^hash),
            set: [created_by: creator]
          )

        result =
          conn
          |> put_req_header("authorization", "Bearer " <> api_key)
          |> authenticate(errors: Emissary.Web.MCPError)

        assert result.halted
        assert result.status == 401
      end
    end

    test "authenticates with valid API key", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> authenticate()

      refute conn.halted
      ctx = conn.assigns[:context]

      assert ctx.auth_method == :api_key
      # Application keys get default scopes: execute, component_read, storage_read
      assert ctx.permissions ==
               MapSet.new([:execute, :component_read, :storage_read])
    end

    test "returns 401 for invalid API key", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer cyfr_pk_invalid123456789012345678")
        |> authenticate(errors: Emissary.Web.MCPError)

      assert conn.halted
      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["message"] =~ "Invalid API key"
    end

    # Every HTTP 401 must include an authentication challenge (RFC 9110).
    test "every 401 carries a WWW-Authenticate challenge", %{conn: conn} do
      for authorization <- [
            "Bearer cyfr_pk_invalid123456789012345678",
            "Bearer not-a-real-session-token"
          ] do
        conn =
          conn
          |> put_req_header("authorization", authorization)
          |> authenticate()

        assert conn.status == 401, "expected 401 for #{authorization}"
        assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      end
    end

    test "a Sanctum session token authenticates as a bearer credential", %{conn: conn} do
      # Stateless auth: the credential travels on the request itself, so no
      # server-side MCP session is created and nothing is cached.
      ctx = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
      {:ok, session} = Sanctum.Session.create(ctx)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{session.token}")
        |> authenticate()

      refute conn.halted
      assert conn.assigns[:context].auth_method == :oidc
      assert conn.assigns[:context].user_id == ctx.user_id
      assert conn.assigns[:context].authenticated
    end

    test "a destroyed session token stops authenticating immediately", %{conn: conn} do
      # The bearer path reads the row on every request, so revocation takes
      # effect on the next call rather than when a cache entry expires.
      ctx = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
      {:ok, session} = Sanctum.Session.create(ctx)
      :ok = Sanctum.Session.destroy(session.token)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{session.token}")
        |> authenticate()

      resolved = conn.assigns[:context]
      refute resolved && resolved.user_id == ctx.user_id && resolved.authenticated
    end

    test "API key auth bypasses session requirement", %{conn: conn, api_key: api_key} do
      # API keys should work without any session
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> authenticate()

      refute conn.halted
      assert conn.assigns[:context].auth_method == :api_key
    end

    test "context has authenticated: true for valid API key", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> authenticate()

      refute conn.halted
      ctx = conn.assigns[:context]
      assert ctx.authenticated == true
    end
  end

  describe "call/2 - auth enforcement" do
    test "rejects a person whose session has no athanor to work in with 403", %{conn: conn} do
      # A person this server knows, whose own athanor is archived since
      # their session was minted: nowhere to work.
      {:ok, person} =
        Sanctum.Test.People.linked(%{
          id: "github|https://github.com|no-athanor-#{System.unique_integer([:positive])}",
          provider: "github"
        })

      athanor = Sanctum.Test.People.athanor!(person)

      {:ok, session} =
        Sanctum.TestContext.create_session(
          Sanctum.Context.build(
            user_id: person.id,
            provider: "github",
            athanor_id: athanor.id,
            permissions: Sanctum.Context.person_permissions(),
            auth_method: :oidc
          )
        )

      Sanctum.TestContext.archive!(athanor.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> session.token)
        |> authenticate(errors: Emissary.Web.MCPError)

      assert conn.halted
      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["message"] =~ "no athanor"
    end
  end

  describe "IP address extraction" do
    test "handles empty X-Forwarded-For header gracefully", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-forwarded-for", "")
        |> authenticate()

      # Should not crash, should use remote_ip fallback
      refute conn.halted
      assert conn.assigns[:context]
    end

    test "handles malformed X-Forwarded-For header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-forwarded-for", "not-an-ip, also-not-an-ip")
        |> authenticate()

      # Should not crash, should use remote_ip fallback
      refute conn.halted
      assert conn.assigns[:context]
    end

    test "handles valid X-Forwarded-For with multiple IPs", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-forwarded-for", "192.168.1.1, 10.0.0.1, 172.16.0.1")
        |> authenticate()

      # Should take first IP
      refute conn.halted
      assert conn.assigns[:context]
    end
  end
end
