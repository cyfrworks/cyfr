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

  defp authed_org_ctx do
    Context.build(
      user_id: "u-1",
      namespace: "ns-1",
      org_id: "acme",
      project_id: "proj-1",
      permissions: [:read, :write],
      scope: :project,
      auth_method: :oidc,
      authenticated: true
    )
  end

  describe "issue_access_token/1 + ?_t= round-trip" do
    test "mints a token that rebuilds a project-scoped :execute tincture context" do
      token = TinctureAuth.issue_access_token(authed_org_ctx())

      assert {:ok, %Context{} = out} = TinctureAuth.authenticate(conn("_t=#{token}"))
      assert out.user_id == "u-1"
      assert out.namespace == "ns-1"
      assert out.org_id == "acme"
      assert out.project_id == "proj-1"
      assert out.scope == :project
      assert out.auth_method == :tincture
      assert out.authenticated == true
      assert MapSet.to_list(out.permissions) == [:execute]
    end

    test "a tampered/garbage ?_t= is rejected" do
      assert TinctureAuth.authenticate(conn("_t=not-a-valid-token")) == :unauthenticated
    end

    test "?_t= still flows through the platform-mode tenant gate" do
      # An org-less context's token must not authenticate under strict policy.
      orgless_token = TinctureAuth.issue_access_token(Sanctum.TestContext.local())

      fn -> assert TinctureAuth.authenticate(conn("_t=#{orgless_token}")) == :unauthenticated end
    end
  end

  describe "header-preferred resolution" do
    test "Authorization: Bearer cyfr_… authenticates with no query string", %{ctx: ctx} do
      {:ok, %{key: key}} = Sanctum.ApiKey.create(ctx, %{name: "bearer-key"})

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

    test "header wins over a bogus legacy query param", %{ctx: ctx} do
      {:ok, %{key: key}} = Sanctum.ApiKey.create(ctx, %{name: "order-key"})

      cn = conn("_key=cyfr_pk_bogus", [{"authorization", "Bearer #{key}"}])
      assert {:ok, %Context{auth_method: :api_key}} = TinctureAuth.authenticate(cn)
    end
  end

  describe "legacy query params still work (additive — removed later)" do
    test "raw ?_key=cyfr_… still authenticates", %{ctx: ctx} do
      {:ok, %{key: key}} = Sanctum.ApiKey.create(ctx, %{name: "legacy-key"})
      assert {:ok, %Context{}} = TinctureAuth.authenticate(conn("_key=#{key}"))
    end

    test "no credentials → :unauthenticated" do
      assert TinctureAuth.authenticate(conn("")) == :unauthenticated
    end
  end
end
