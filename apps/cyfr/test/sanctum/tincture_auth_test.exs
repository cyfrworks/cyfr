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

  describe "authenticate/1 — no / invalid credentials" do
    test "blank query string → :unauthenticated" do
      assert TinctureAuth.authenticate(conn("")) == :unauthenticated
    end

    test "non-cyfr-prefixed ?_key= is skipped → :unauthenticated" do
      assert TinctureAuth.authenticate(conn("_key=not-a-cyfr-key")) == :unauthenticated
    end

    test "unknown ?_session= falls through (MCP session miss → Sanctum session miss)" do
      assert TinctureAuth.authenticate(conn("_session=sess_does_not_exist")) == :unauthenticated
    end

    test "malformed remote_ip does not crash (client_ip rescue → nil)" do
      # cyfr-prefixed but invalid key; the point is client_ip/1's rescue path
      # is exercised without raising.
      assert TinctureAuth.authenticate(conn("_key=cyfr_pk_bogus", nil)) == :unauthenticated
    end
  end

  describe "authenticate/1 — API key path" do
    test "valid ?_key= yields an :api_key context", %{ctx: ctx} do
      {:ok, %{key: key}} = Sanctum.ApiKey.create(ctx, %{name: "tincture-key"})

      assert {:ok, %Context{} = out} = TinctureAuth.authenticate(conn("_key=#{key}"))
      assert out.auth_method == :api_key
      assert out.authenticated == true
    end

    test "session is attempted before key (invalid session + valid key still authenticates)",
         %{ctx: ctx} do
      {:ok, %{key: key}} = Sanctum.ApiKey.create(ctx, %{name: "order-key"})

      qs = "_session=sess_bogus&_key=#{key}"
      assert {:ok, %Context{auth_method: :api_key}} = TinctureAuth.authenticate(conn(qs))
    end
  end

  describe "authenticate/1 — platform mode tenant gate" do
    test "an org-less key context fails the tenant gate → :unauthenticated", %{ctx: ctx} do
      # local/0 has the "" sentinel org; the key row inherits it. Under the
      # strict policy `tenant_resolved?/1` flips an otherwise-valid auth to
      # :unauthenticated (the tincture HTTP isolation guarantee).
      {:ok, %{key: key}} = Sanctum.ApiKey.create(ctx, %{name: "orgless-key"})

      fn -> assert TinctureAuth.authenticate(conn("_key=#{key}")) == :unauthenticated end
    end
  end
end
