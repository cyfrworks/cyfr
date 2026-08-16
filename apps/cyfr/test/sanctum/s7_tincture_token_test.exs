# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.S7TinctureTokenTest do
  @moduledoc """
  Phase 2 S7 (additive increment): header-preferred resolution + the
  short-lived `?_t=` access token. Raw `?_session=`/`?_key=` still work
  (removed in the later cross-component step), so this proves the new paths
  without breaking existing clients.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.TinctureAuth

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp conn(query_string, headers \\ []) do
    %Plug.Conn{query_string: query_string, req_headers: headers, remote_ip: {127, 0, 0, 1}}
  end

  defp authed_ctx do
    Context.build(
      user_id: "u-1",
      namespace: "ns-1",
      athanor_id: "ath_acme",
      permissions: [:read, :write],
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  describe "issue_access_token/1 + ?_t= round-trip" do
    test "mints a token that rebuilds an athanor-scoped :execute tincture context" do
      token = TinctureAuth.issue_access_token(authed_ctx())

      assert {:ok, %Context{} = out} = TinctureAuth.authenticate(conn("_t=#{token}"))
      assert out.user_id == "u-1"
      assert out.namespace == "ns-1"
      assert out.athanor_id == "ath_acme"
      assert out.scope == :athanor
      assert out.auth_method == :tincture
      assert out.authenticated == true
      assert MapSet.to_list(out.permissions) == [:execute]
    end

    test "a tampered/garbage ?_t= is rejected" do
      assert TinctureAuth.authenticate(conn("_t=not-a-valid-token")) == :unauthenticated
    end

    test "?_t= still flows through the tenant gate" do
      # An athanor-less context's token must not authenticate: the token
      # carries no athanor, and the rebuilt context fails tenant_ok/1.
      unresolved =
        Context.build(
          user_id: "u-2",
          namespace: "ns-2",
          athanor_id: nil,
          permissions: [:read],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )

      token = TinctureAuth.issue_access_token(unresolved)
      assert TinctureAuth.authenticate(conn("_t=#{token}")) == :unauthenticated
    end
  end

  describe "header-preferred resolution" do
    test "Authorization: Bearer cyfr_… authenticates with no query string", %{ctx: ctx} do
      {:ok, %{api_key: key}} = Sanctum.ApiKey.create(ctx, %{name: "bearer-key"})

      assert {:ok, %Context{auth_method: :api_key}} =
               TinctureAuth.authenticate(conn("", [{"authorization", "Bearer #{key}"}]))
    end

    test "non-cyfr Bearer is skipped" do
      assert TinctureAuth.authenticate(conn("", [{"authorization", "Bearer abc"}])) ==
               :unauthenticated
    end

    test "unknown Mcp-Session-Id header falls through to :unauthenticated" do
      assert TinctureAuth.authenticate(conn("", [{"mcp-session-id", "sess_nope"}])) ==
               :unauthenticated
    end

    test "the header is what authenticates, whatever the query string says", %{ctx: ctx} do
      {:ok, %{api_key: key}} = Sanctum.ApiKey.create(ctx, %{name: "order-key"})

      cn = conn("_key=cyfr_pk_bogus", [{"authorization", "Bearer #{key}"}])
      assert {:ok, %Context{auth_method: :api_key}} = TinctureAuth.authenticate(cn)
    end
  end

  describe "account credentials are not accepted from a query string" do
    test "a valid ?_key=cyfr_… no longer authenticates", %{ctx: ctx} do
      {:ok, %{api_key: key}} = Sanctum.ApiKey.create(ctx, %{name: "legacy-key"})

      # This path was kept while Porta still built iframe URLs with a raw
      # credential. Porta now mints the scoped ?_t= token instead, so the
      # query channel is closed: a URL is visible in browser history, Referer
      # and every intermediary log.
      assert TinctureAuth.authenticate(conn("_key=#{key}")) == :unauthenticated

      cn = conn("", [{"authorization", "Bearer #{key}"}])
      assert {:ok, %Context{}} = TinctureAuth.authenticate(cn)
    end

    test "no credentials → :unauthenticated" do
      assert TinctureAuth.authenticate(conn("")) == :unauthenticated
    end
  end
end
