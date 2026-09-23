# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TinctureAuthTest do
  # async: false — API-key validation hits the shared Arca.Repo sandbox.
  use ExUnit.Case, async: false

  require Ecto.Query

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

    test "a presented non-session bearer is a named refusal, not silence" do
      assert TinctureAuth.authenticate(bearer_conn("not-a-cyfr-key")) ==
               {:error, :invalid_credential}
    end

    test "an unknown session bearer is refused by name" do
      assert TinctureAuth.authenticate(bearer_conn("sess_does_not_exist")) ==
               {:error, :invalid_credential}
    end

    test "malformed remote_ip does not crash (client_ip rescue → nil)" do
      # cyfr-prefixed but invalid key; the point is client_ip/1's rescue path
      # is exercised without raising.
      assert TinctureAuth.authenticate(bearer_conn("cyfr_pk_bogus", nil)) ==
               {:error, :invalid_credential}
    end
  end

  describe "authenticate/1 — credentials are never accepted from a query string" do
    test "a valid API key in ?_key= does not authenticate", %{ctx: ctx} do
      ctx = Sanctum.TestContext.issuer!(ctx)
      {:ok, %{api_key: key}} = Sanctum.ApiKey.create(ctx, %{name: "query-key"})

      # Valid credential, wrong channel. A URL reaches browser history, Referer
      # and proxy logs, so only the scoped ?_t= token may travel there.
      assert TinctureAuth.authenticate(conn("_key=#{key}")) == :unauthenticated
      assert {:ok, %Context{}} = TinctureAuth.authenticate(bearer_conn(key))
    end

    test "a session id in ?_session= does not authenticate", %{ctx: ctx} do
      {:ok, session} = Sanctum.Session.create(Sanctum.TestContext.issuer!(ctx))

      assert TinctureAuth.authenticate(conn("_session=#{session.token}")) == :unauthenticated
    end
  end

  # Session tokens authenticate through the Authorization header.
  describe "authenticate/1 — session-token path" do
    test "a bearer session token authenticates, carrying the recorded namespace",
         %{ctx: ctx} do
      # `Session.load` reads the namespace from the users row.
      {ctx, user} = Sanctum.TestContext.person!(ctx, %{email: "testns@example.com"})
      {:ok, _} = Sanctum.Tenancy.Users.set_namespace(user, ctx.namespace)

      # A restored session is re-validated against current memberships; the
      # test user must actually be a member of the athanor it works in.
      Sanctum.TestContext.athanor!()

      {:ok, _} =
        Sanctum.Tenancy.Members.ensure(ctx.user_id, scope: "athanor", athanor_id: ctx.athanor_id)

      {:ok, session} =
        Sanctum.Session.create(ctx, generation_snapshot: Sanctum.TestContext.snapshot!(ctx))

      assert {:ok, %Context{} = out} = TinctureAuth.authenticate(bearer_conn(session.token))

      # Tincture access always runs athanor-scoped, whatever the operator's
      # console happened to be doing.
      assert out.auth_method == :session
      assert out.scope == :athanor
      assert out.authenticated
    end

    # The establish memo bounds establishing, not validating: what it answers
    # is revalidated against the stored session before this surface admits it.
    test "a session revoked behind a warm memo is refused", %{ctx: ctx} do
      original = Application.fetch_env(:sanctum, :caller_memo_ttl_ms)
      Application.put_env(:sanctum, :caller_memo_ttl_ms, 60_000)

      on_exit(fn ->
        Arca.Cache.delete_match({:established, :_, :_, :_})

        case original do
          {:ok, value} -> Application.put_env(:sanctum, :caller_memo_ttl_ms, value)
          :error -> Application.delete_env(:sanctum, :caller_memo_ttl_ms)
        end
      end)

      ctx = Sanctum.TestContext.issuer!(ctx)

      {:ok, session} =
        Sanctum.Session.create(ctx, generation_snapshot: Sanctum.TestContext.snapshot!(ctx))

      assert {:ok, %Context{}} = TinctureAuth.authenticate(bearer_conn(session.token))

      hash = Sanctum.Session.token_hash(session.token)

      Arca.Repo.delete_all(
        Ecto.Query.from(s in Arca.Schemas.Session, where: s.token_hash == ^hash)
      )

      assert {:error, :invalid_credential} = TinctureAuth.authenticate(bearer_conn(session.token))
    end

    # A publisher namespace is not identity: a person without one goes
    # through the same establish as anyone, on the athanor their membership
    # grants.
    test "a person without a namespace authenticates like anyone else, athanor-scoped", %{
      ctx: ctx
    } do
      {ctx, _user} = Sanctum.TestContext.person!(ctx)

      {:ok, estate} =
        Sanctum.Tenancy.Athanors.create_group(
          ctx.user_id,
          "Tincture #{System.unique_integer([:positive])}"
        )

      {:ok, _} =
        Sanctum.Tenancy.Members.ensure(ctx.user_id, scope: "athanor", athanor_id: estate.id)

      session_ctx = %{ctx | namespace: nil, athanor_id: estate.id}

      {:ok, session} =
        Sanctum.Session.create(session_ctx,
          generation_snapshot: Sanctum.TestContext.snapshot!(session_ctx)
        )

      assert {:ok, %Context{} = out} = TinctureAuth.authenticate(bearer_conn(session.token))
      assert out.scope == :athanor
      assert out.authenticated
      assert out.namespace == nil
      assert out.athanor_id == estate.id
    end
  end

  describe "authenticate/1 — API key path" do
    test "a bearer API key yields an :api_key context", %{ctx: ctx} do
      ctx = Sanctum.TestContext.issuer!(ctx)
      {:ok, %{api_key: key}} = Sanctum.ApiKey.create(ctx, %{name: "tincture-key"})

      assert {:ok, %Context{} = out} = TinctureAuth.authenticate(bearer_conn(key))
      assert out.auth_method == :api_key
      assert out.authenticated == true
    end
  end

  describe "authenticate/1 — tenant gate" do
    test "a session that resolves to no athanor is refused by name" do
      # A signed-in user with no membership carries no athanor. The tincture
      # surface still stamps scope :athanor / authenticated, but the tenant
      # gate refuses a context that names no athanor (the tincture HTTP
      # isolation guarantee) — and says so.
      {unresolved, _user} =
        Context.build(
          user_id: "github|https://github.com|nowhere-#{System.unique_integer([:positive])}",
          email: "nowhere@example.com",
          provider: "github",
          athanor_id: nil,
          permissions: [:execute],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )
        |> Sanctum.TestContext.person!()

      {:ok, session} =
        Sanctum.Session.create(unresolved,
          generation_snapshot: Sanctum.TestContext.snapshot!(unresolved)
        )

      assert TinctureAuth.authenticate(bearer_conn(session.token)) ==
               {:error, :no_athanor}
    end
  end

  describe "authenticate/1 — a denied person's surviving session" do
    test "is refused, not re-upgraded", %{ctx: ctx} do
      {ctx, user} = Sanctum.TestContext.person!(ctx, %{email: "denied-tincture@example.com"})
      {:ok, _} = Sanctum.Tenancy.Users.set_namespace(user, ctx.namespace)
      Sanctum.TestContext.athanor!()

      {:ok, _} =
        Sanctum.Tenancy.Members.ensure(ctx.user_id, scope: "athanor", athanor_id: ctx.athanor_id)

      {:ok, session} =
        Sanctum.Session.create(ctx, generation_snapshot: Sanctum.TestContext.snapshot!(ctx))

      assert {:ok, %Context{}} = TinctureAuth.authenticate(bearer_conn(session.token))

      # Mark the row denied WITHOUT `Users.deny/1`'s session revocation —
      # the race window between an operator's deny and its reconcile. The
      # old blanket upgrade re-authenticated exactly this session.
      {:ok, _} =
        Arca.Schemas.User
        |> Arca.Repo.get!(user.id)
        |> Ecto.Changeset.change(status: "denied")
        |> Arca.Repo.update()

      Sanctum.Caller.invalidate_hash(Sanctum.Session.token_hash(session.token))

      assert TinctureAuth.authenticate(bearer_conn(session.token)) == {:error, :denied}
    end
  end
end
