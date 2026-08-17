# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TinctureAuthTest do
  # async: false — API-key validation hits the shared Arca.Repo sandbox.
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.TinctureAuth

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp conn(query_string, remote_ip \\ {127, 0, 0, 1}) do
    %Plug.Conn{query_string: query_string, remote_ip: remote_ip}
  end

  defp bearer_conn(token, remote_ip \\ {127, 0, 0, 1}) do
    %Plug.Conn{
      query_string: "",
      remote_ip: remote_ip,
      req_headers: [{"authorization", "Bearer " <> token}]
    }
  end

  describe "authenticate/1 — no / invalid credentials" do
    test "blank query string → :unauthenticated" do
      assert TinctureAuth.authenticate(conn("")) == :unauthenticated
    end

    test "a non-cyfr bearer token that is no session → :unauthenticated" do
      assert TinctureAuth.authenticate(bearer_conn("not-a-cyfr-key")) == :unauthenticated
    end

    test "an unknown session bearer falls through → :unauthenticated" do
      assert TinctureAuth.authenticate(bearer_conn("sess_does_not_exist")) == :unauthenticated
    end

    test "malformed remote_ip does not crash (client_ip rescue → nil)" do
      # cyfr-prefixed but invalid key; the point is client_ip/1's rescue path
      # is exercised without raising.
      assert TinctureAuth.authenticate(bearer_conn("cyfr_pk_bogus", nil)) == :unauthenticated
    end
  end

  describe "authenticate/1 — credentials are never accepted from a query string" do
    test "a valid API key in ?_key= does not authenticate", %{ctx: ctx} do
      {:ok, %{api_key: key}} = Sanctum.ApiKey.create(ctx, %{name: "query-key"})

      # Valid credential, wrong channel. A URL reaches browser history, Referer
      # and proxy logs, so only the scoped ?_t= token may travel there.
      assert TinctureAuth.authenticate(conn("_key=#{key}")) == :unauthenticated
      assert {:ok, %Context{}} = TinctureAuth.authenticate(bearer_conn(key))
    end

    test "a session id in ?_session= does not authenticate", %{ctx: ctx} do
      {:ok, session} = Sanctum.Session.create(ctx)

      assert TinctureAuth.authenticate(conn("_session=#{session.token}")) == :unauthenticated
    end
  end

  # The `Mcp-Session-Id` header used to be a third way to present exactly this
  # credential. It went out with the protocol session it was named for, so the
  # bearer branch is now the only route a session token takes — which makes it
  # worth asserting directly rather than only through a controller.
  describe "authenticate/1 — session-token path" do
    test "a bearer session token authenticates once the namespace is claimed",
         %{ctx: ctx} do
      # `Session.load` resolves through the namespace on the users row, and a
      # person with none loads as unauthenticated by design — the claim gate
      # runs before anything tenant-scoped.
      {:ok, user} =
        Sanctum.Tenancy.Users.upsert_from_provider(%{
          id: ctx.user_id,
          provider: "local",
          email: "testns@example.com",
          verified: true
        })

      {:ok, _} = Sanctum.Tenancy.Users.set_namespace(user, ctx.namespace)

      # A restored session is re-validated against current memberships; the
      # test user must actually be a member of the athanor it works in.
      Sanctum.TestContext.athanor!()

      {:ok, _} =
        Sanctum.Tenancy.Members.ensure(ctx.user_id, scope: "athanor", athanor_id: ctx.athanor_id)

      {:ok, session} = Sanctum.Session.create(ctx)

      assert {:ok, %Context{} = out} = TinctureAuth.authenticate(bearer_conn(session.token))

      # Tincture access always runs athanor-scoped, whatever the operator's
      # console happened to be doing.
      assert out.auth_method == :session
      assert out.scope == :athanor
      assert out.authenticated
    end

    # Deliberate, and documented in `try_sanctum_session/1`: a user who has not
    # yet claimed a namespace loads as unauthenticated for the console, because
    # the claim gate must run first — but tincture access is not tenant
    # administration and is granted anyway, athanor-scoped. What the resulting
    # context can then *do* is decided by its permissions, not by this branch.
    test "an unclaimed user still authenticates, athanor-scoped", %{ctx: ctx} do
      {:ok, session} = Sanctum.Session.create(ctx)

      assert {:ok, %Context{} = out} = TinctureAuth.authenticate(bearer_conn(session.token))
      assert out.scope == :athanor
      # The session's persisted athanor rides along — it is what lets the
      # tenant gate pass for a user who has not claimed a namespace yet.
      assert out.athanor_id == ctx.athanor_id
    end
  end

  describe "authenticate/1 — API key path" do
    test "a bearer API key yields an :api_key context", %{ctx: ctx} do
      {:ok, %{api_key: key}} = Sanctum.ApiKey.create(ctx, %{name: "tincture-key"})

      assert {:ok, %Context{} = out} = TinctureAuth.authenticate(bearer_conn(key))
      assert out.auth_method == :api_key
      assert out.authenticated == true
    end
  end

  describe "authenticate/1 — tenant gate" do
    test "a session that resolves to no athanor fails the tenant gate → :unauthenticated" do
      # A signed-in user with no membership carries no athanor. The tincture
      # surface still stamps scope :athanor / authenticated, but
      # `tenant_resolved?/1` flips the otherwise-valid auth to
      # :unauthenticated (the tincture HTTP isolation guarantee).
      unresolved =
        Context.build(
          user_id: "u-nowhere-#{System.unique_integer([:positive])}",
          email: "nowhere@example.com",
          provider: "github",
          athanor_id: nil,
          permissions: [:execute],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )

      {:ok, session} = Sanctum.Session.create(unresolved)

      assert TinctureAuth.authenticate(bearer_conn(session.token)) == :unauthenticated
    end
  end
end
