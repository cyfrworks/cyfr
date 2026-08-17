# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.RequirePersonalNamespaceTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias EmissaryWeb.Plugs.RequirePersonalNamespace
  alias Sanctum.{Context, Session}

  @endpoint_opts [
    store: :cookie,
    key: "_test_cookie_key",
    signing_salt: "test_salt",
    encryption_salt: "test_salt_enc"
  ]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path =
      Path.join(System.tmp_dir!(), "require_personal_namespace_test_#{:rand.uniform(100_000)}")

    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    original_oci = Application.get_env(:cyfr, :oci_registry_url)
    registry = "registry.cyfr.run.test"
    Application.put_env(:cyfr, :oci_registry_url, registry)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)

      if original_oci,
        do: Application.put_env(:cyfr, :oci_registry_url, original_oci),
        else: Application.delete_env(:cyfr, :oci_registry_url)
    end)

    {:ok, registry: registry}
  end

  describe "bypass paths" do
    test "/claim-namespace is bypassed" do
      conn = build_conn(:get, "/claim-namespace")
      result = RequirePersonalNamespace.call(conn, [])
      refute result.halted
      refute result.status
    end

    test "/auth/github is bypassed" do
      conn = build_conn(:get, "/auth/github")
      result = RequirePersonalNamespace.call(conn, [])
      refute result.halted
    end

    test "/mcp is bypassed" do
      conn = build_conn(:post, "/mcp")
      result = RequirePersonalNamespace.call(conn, [])
      refute result.halted
    end

    test "/assets/app.css is bypassed" do
      conn = build_conn(:get, "/assets/app.css")
      result = RequirePersonalNamespace.call(conn, [])
      refute result.halted
    end

    test "/t/home/alice/demo is bypassed" do
      conn = build_conn(:get, "/t/home/alice/demo")
      result = RequirePersonalNamespace.call(conn, [])
      refute result.halted
    end
  end

  describe "anonymous users" do
    test "are not redirected (route-level auth handles them)" do
      conn = build_conn(:get, "/dashboard")
      result = RequirePersonalNamespace.call(conn, [])
      refute result.halted
      refute result.status
    end
  end

  describe "authed users" do
    test "whose users row records a namespace pass through", %{registry: registry} do
      user = build_user()
      claim!(user, "alice")
      {:ok, session} = Session.create(user)

      conn = authed_conn(session.token)
      result = RequirePersonalNamespace.call(conn, [])

      refute result.halted
      refute result.status

      # Push tokens are not what lets them through: without any, still in.
      :ok = Compendium.Registry.CredentialStore.delete(user.user_id, registry, "alice")
      Sanctum.Namespace.invalidate(user.user_id)
      result = RequirePersonalNamespace.call(authed_conn(session.token), [])
      refute result.halted
    end

    test "with push tokens but no recorded namespace are redirected", %{registry: registry} do
      user = build_user()
      seed_row(user)
      {:ok, session} = Session.create(user)

      # A publisher token, and even a bare-slug token, is a credential — not
      # an identity. The users row decides.
      for slug <- ["stripe.com", "alice"] do
        :ok =
          Compendium.Registry.CredentialStore.put_push_token(
            user.user_id,
            registry,
            slug,
            "cyfr_pt_#{slug}",
            "personal"
          )
      end

      conn = authed_conn(session.token)
      result = RequirePersonalNamespace.call(conn, [])

      assert result.halted
      assert result.status in [302, 303]
      assert Plug.Conn.get_resp_header(result, "location") == ["/claim-namespace"]
    end

    test "with no namespace are redirected" do
      user = build_user()
      seed_row(user)
      {:ok, session} = Session.create(user)

      conn = authed_conn(session.token)
      result = RequirePersonalNamespace.call(conn, [])

      assert result.halted
      assert Plug.Conn.get_resp_header(result, "location") == ["/claim-namespace"]
    end

    test "denied at the door since the session was minted are sent to /login, not the claim" do
      user = build_user()
      claim!(user, "denied")
      {:ok, row} = Sanctum.Tenancy.Users.get(user.user_id)
      {:ok, _} = Sanctum.Tenancy.Users.deny(row)

      # A session that loads after the deny carries the namespace but no
      # standing — the shape the plug must tell from "not claimed yet".
      {:ok, session} = Session.create(user)

      case Session.load(session.token, surface: :console) do
        {:ok, %{authenticated: false, namespace: ns}} when is_binary(ns) ->
          result = RequirePersonalNamespace.call(authed_conn(session.token), [])
          assert result.halted
          assert Plug.Conn.get_resp_header(result, "location") == ["/login"]

        other ->
          flunk("expected an unauthenticated context with a namespace, got #{inspect(other)}")
      end
    end

    test "/claim-namespace-fake is NOT bypassed (prefix boundary)" do
      user = build_user()
      seed_row(user)
      {:ok, session} = Session.create(user)

      conn =
        build_conn(:get, "/claim-namespace-fake")
        |> put_session(:sanctum_session_token, session.token)

      result = RequirePersonalNamespace.call(conn, [])

      assert result.halted
      assert Plug.Conn.get_resp_header(result, "location") == ["/claim-namespace"]
    end

    test "a session this server does not recognise passes through (route auth handles it)" do
      conn = authed_conn("cyfr_sess_not_a_real_token")
      result = RequirePersonalNamespace.call(conn, [])
      refute result.halted
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp build_user do
    Context.build(
      user_id: "github|https://github.com|#{System.unique_integer([:positive])}",
      email: "test-#{System.unique_integer([:positive])}@example.com",
      provider: "github",
      athanor_id: "ath_test",
      permissions: [],
      namespace: "testns",
      authenticated: true
    )
  end

  # The person as the door records them, with or without a namespace.
  defp seed_row(user) do
    {:ok, row} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: user.user_id,
        provider: "github",
        email: user.email,
        verified: true
      })

    row
  end

  defp claim!(user, slug) do
    {:ok, _} = user |> seed_row() |> Sanctum.Tenancy.Users.set_namespace(slug)
    :ok
  end

  defp build_conn(method, path) do
    conn(method, path)
    |> Map.put(:secret_key_base, String.duplicate("a", 64))
    |> Plug.Session.call(Plug.Session.init(@endpoint_opts))
    |> fetch_session()
  end

  defp authed_conn(session_token) do
    build_conn(:get, "/dashboard")
    |> put_session(:sanctum_session_token, session_token)
  end
end
