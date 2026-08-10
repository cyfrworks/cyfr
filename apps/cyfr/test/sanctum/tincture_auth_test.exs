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
      {:ok, %{key: key}} = Sanctum.ApiKey.create(ctx, %{name: "query-key"})

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

  describe "authenticate/1 — API key path" do
    test "a bearer API key yields an :api_key context", %{ctx: ctx} do
      {:ok, %{key: key}} = Sanctum.ApiKey.create(ctx, %{name: "tincture-key"})

      assert {:ok, %Context{} = out} = TinctureAuth.authenticate(bearer_conn(key))
      assert out.auth_method == :api_key
      assert out.authenticated == true
    end
  end

  describe "authenticate/1 — platform mode tenant gate" do
    test "an org-less key context fails the tenant gate → :unauthenticated", %{ctx: ctx} do
      # local/0 has the "" sentinel org; the key row inherits it. Under the
      # strict policy `tenant_resolved?/1` flips an otherwise-valid auth to
      # :unauthenticated (the tincture HTTP isolation guarantee).
      {:ok, %{key: key}} = Sanctum.ApiKey.create(ctx, %{name: "orgless-key"})

      fn -> assert TinctureAuth.authenticate(bearer_conn(key)) == :unauthenticated end
    end
  end
end
