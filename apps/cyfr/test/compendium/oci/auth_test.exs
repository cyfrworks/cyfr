# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.OCI.AuthTest do
  use ExUnit.Case, async: false

  alias Compendium.OCI.Auth
  alias Compendium.Registry.CredentialStore
  alias Sanctum.Context

  @registry "registry.test.example"
  @user "oci_auth_test_user"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    for slug <- ["alice", "stripe.com"] do
      CredentialStore.delete(ctx(), @registry, slug)
    end

    :ok
  end

  defp ctx do
    Context.build(
      user_id: @user,
      athanor_id: "ath_test",
      permissions: [:*],
      scope: :athanor,
      auth_method: :oidc,
      namespace: "testns",
      authenticated: true
    )
  end

  describe "fetch_credential/3" do
    test "returns :anonymous when no credential is stored" do
      assert Auth.fetch_credential(@registry, "alice", ctx()) == :anonymous
    end

    test "returns :anonymous when ctx is nil (no cross-user fallback)" do
      :ok = CredentialStore.put_push_token(ctx(), @registry, "alice", "cyfr_pt_fake", "personal")

      assert Auth.fetch_credential(@registry, "alice", nil) == :anonymous
    end

    test "returns the push-token credential when one is stored for the user+namespace" do
      :ok =
        CredentialStore.put_push_token(
          ctx(),
          @registry,
          "alice",
          "cyfr_pt_alice_token",
          "personal"
        )

      assert {:ok, fetched} = Auth.fetch_credential(@registry, "alice", ctx())
      assert fetched.type == :push_token
      assert fetched.token == "cyfr_pt_alice_token"
      assert fetched.namespace == "alice"
    end

    test "scoped per-namespace: alice's token does not surface for stripe.com" do
      :ok = CredentialStore.put_push_token(ctx(), @registry, "alice", "cyfr_pt_alice", "personal")

      assert Auth.fetch_credential(@registry, "stripe.com", ctx()) == :anonymous
    end
  end

  describe "auth_headers/4" do
    test "returns empty headers when no credential exists (anonymous pull)" do
      assert {:ok, []} = Auth.auth_headers(@registry, "alice/catalysts/foo", "alice", ctx())
    end

    test "emits Bearer <push_token> when a push token is stored" do
      :ok =
        CredentialStore.put_push_token(ctx(), @registry, "alice", "cyfr_pt_abc123", "personal")

      assert {:ok, [{"authorization", "Bearer cyfr_pt_abc123"}]} =
               Auth.auth_headers(@registry, "alice/catalysts/foo", "alice", ctx())
    end
  end
end
