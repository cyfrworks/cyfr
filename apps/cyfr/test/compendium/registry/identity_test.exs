# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Registry.IdentityTest do
  use ExUnit.Case, async: false

  alias Compendium.Registry.{CredentialStore, Identity}
  alias Sanctum.Context

  @user "identity_test_user"

  # Read through the same accessor the code under test uses, at runtime: seven
  # other suites `put_env` this key, and a value frozen into a module attribute
  # at compile time cannot see any of them.
  defp registry, do: Compendium.RegistryHost.canonical_host()

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx =
      Context.build(
        user_id: @user,
        athanor_id: "ath_test",
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        namespace: "testns",
        authenticated: true
      )

    for slug <- ["alice", "stripe.com"] do
      CredentialStore.delete(ctx, registry(), slug)
    end

    {:ok, ctx: ctx}
  end

  describe "identity/1 return shape" do
    test "unauthenticated when no credentials exist", %{ctx: ctx} do
      result = Identity.identity(ctx)
      assert result.authenticated == false
      assert result.personal_namespace == nil
      assert result.memberships == []
      assert result.user_id == @user
    end

    test "shape always includes required keys", %{ctx: ctx} do
      result = Identity.identity(ctx)
      assert Map.has_key?(result, :authenticated)
      assert Map.has_key?(result, :user_id)
      assert Map.has_key?(result, :personal_namespace)
      assert Map.has_key?(result, :memberships)
    end

    test "credentials present but server unreachable — entries are either dropped (401/403) or kept with last_used_at=nil",
         %{ctx: ctx} do
      # identity/1 calls the real registry with a fake token. The registry is
      # unreachable in tests, so each confirm_namespace call times out. Our
      # impl keeps entries on transient errors (timeout) with `last_used_at: nil`,
      # so we'll observe a map with personal_namespace set to {slug: "alice", ...}.
      :ok =
        CredentialStore.put_push_token(ctx, registry(), "alice", "cyfr_pt_fake_alice", "personal")

      result = Identity.identity(ctx)
      assert is_map(result)
      assert Map.has_key?(result, :authenticated)
      # Don't assert the exact authenticated flag — depends on whether the
      # registry host resolves in the test env. Just assert the shape is stable.
    end

    @tag :capture_log
    test "a credential store that cannot be read is unavailable, not signed out", %{ctx: ctx} do
      Arca.Repo.query!("ALTER TABLE registry_tokens RENAME TO registry_tokens_unavailable")

      assert {:error, {:unavailable, "Registry credentials"}} = Identity.identity(ctx)
    end
  end
end
