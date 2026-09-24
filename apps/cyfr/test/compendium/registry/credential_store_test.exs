# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Registry.CredentialStoreTest do
  use ExUnit.Case, async: false

  alias Compendium.Registry.CredentialStore

  @reg "registry.test.com"
  @other_reg "other.registry.com"
  @user "test_user_1"
  @user2 "test_user_2"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # Clean up any namespace slots from prior runs.
    for user <- [@user, @user2],
        reg <- [@reg, @other_reg],
        slug <- ["alice", "bob", "stripe.com"] do
      CredentialStore.delete(as(user), reg, slug)
    end

    :ok
  end

  # The store keys by the person a context names, never by an id handed
  # in beside it.
  defp as(user_id),
    do: Sanctum.Context.build(user_id: user_id, authenticated: true, auth_method: :oidc)

  defp token, do: "cyfr_pt_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"

  defp put!(user_id, registry, slug, token \\ token()) do
    :ok = CredentialStore.put_push_token(as(user_id), registry, slug, token, "personal")
    token
  end

  describe "put_push_token/5 + get/3" do
    test "stores and retrieves a push-token credential keyed by namespace" do
      token = put!(@user, @reg, "alice")

      assert {:ok, retrieved} = CredentialStore.get(as(@user), @reg, "alice")
      assert retrieved.type == :push_token
      assert retrieved.token == token
      assert retrieved.namespace == "alice"
      assert retrieved.role == "personal"
      assert retrieved.label == CredentialStore.device_label()
    end

    test "namespaces under the same user are independent slots" do
      a = put!(@user, @reg, "alice")
      s = put!(@user, @reg, "stripe.com")

      assert {:ok, %{token: ^a}} = CredentialStore.get(as(@user), @reg, "alice")
      assert {:ok, %{token: ^s}} = CredentialStore.get(as(@user), @reg, "stripe.com")
    end

    test "overwrites an existing credential on re-put" do
      _first = put!(@user, @reg, "alice")
      second = put!(@user, @reg, "alice")

      assert {:ok, %{token: ^second}} = CredentialStore.get(as(@user), @reg, "alice")
    end

    test "a stored credential of any other type is damaged, not absent" do
      for plaintext <- [~s({"type":1}), ~s({"type":"session"}), ~s({"type":null})] do
        aad = Sanctum.CipherAAD.registry_token(@user, @reg, "alice")
        {:ok, ciphertext} = Sanctum.Cipher.encrypt(plaintext, aad)

        :ok =
          Arca.RegistryTokenStorage.put(%{
            user_id: @user,
            registry: @reg,
            namespace_slug: "alice",
            credential_ciphertext: ciphertext
          })

        assert {:error, :corrupt} = CredentialStore.get(as(@user), @reg, "alice")
      end
    end

    test "returns :not_found for missing slot" do
      assert {:error, :not_found} = CredentialStore.get(as(@user), @reg, "nonexistent")
    end

    test "a slug or token that is not a string stores nothing" do
      assert :skipped = CredentialStore.put_push_token(as(@user), @reg, nil, "t", "personal")
      assert {:ok, []} = CredentialStore.list_for_user(as(@user), @reg)
    end

    test "an empty token stores nothing" do
      assert :skipped = CredentialStore.put_push_token(as(@user), @reg, "alice", "", "personal")
      assert {:error, :not_found} = CredentialStore.get(as(@user), @reg, "alice")
    end
  end

  describe "user + registry isolation" do
    test "different users have separate credentials for the same namespace" do
      a = put!(@user, @reg, "alice")
      b = put!(@user2, @reg, "alice")

      assert {:ok, %{token: ^a}} = CredentialStore.get(as(@user), @reg, "alice")
      assert {:ok, %{token: ^b}} = CredentialStore.get(as(@user2), @reg, "alice")
      assert a != b
    end

    test "different registries have separate credentials for the same slot" do
      t1 = put!(@user, @reg, "alice")
      t2 = put!(@user, @other_reg, "alice")

      assert {:ok, %{token: ^t1}} = CredentialStore.get(as(@user), @reg, "alice")
      assert {:ok, %{token: ^t2}} = CredentialStore.get(as(@user), @other_reg, "alice")
      assert t1 != t2
    end
  end

  describe "list_for_user/2" do
    test "returns empty list when the user has no credentials" do
      assert {:ok, []} = CredentialStore.list_for_user(as("unknown_user"), @reg)
    end

    test "personal-first ordering, then publishers alphabetical" do
      for slug <- ["alice", "stripe.com", "bob"], do: put!(@user, @reg, slug)

      # All three are personal (no dot) except stripe.com.
      # Personal+reserved bucket sorted alphabetically, then publisher bucket.
      assert {:ok, list} = CredentialStore.list_for_user(as(@user), @reg)
      assert length(list) == 3

      slugs = Enum.map(list, & &1.namespace)
      # alice (personal), bob (personal), then stripe.com (publisher)
      assert slugs == ["alice", "bob", "stripe.com"]
    end

    test "does not leak credentials from other users" do
      put!(@user, @reg, "alice")
      put!(@user2, @reg, "bob")

      assert {:ok, list} = CredentialStore.list_for_user(as(@user), @reg)
      assert Enum.map(list, & &1.namespace) == ["alice"]
    end

    test "a bearer is chosen from the usable tokens, past a damaged row" do
      aad = Sanctum.CipherAAD.registry_token(@user, @reg, "alice")
      {:ok, ciphertext} = Sanctum.Cipher.encrypt("not json", aad)

      :ok =
        Arca.RegistryTokenStorage.put(%{
          user_id: @user,
          registry: @reg,
          namespace_slug: "alice",
          credential_ciphertext: ciphertext
        })

      token = put!(@user, @reg, "bob")

      assert {:ok, [%{status: :corrupt}, %{namespace: "bob"}] = entries} =
               CredentialStore.list_for_user(as(@user), @reg)

      assert [%{token: ^token}] = CredentialStore.push_tokens(entries)
    end
  end

  describe "delete/3" do
    test "removes a single namespace slot without touching siblings" do
      put!(@user, @reg, "alice")
      put!(@user, @reg, "stripe.com")

      assert :ok = CredentialStore.delete(as(@user), @reg, "alice")
      assert {:error, :not_found} = CredentialStore.get(as(@user), @reg, "alice")
      assert {:ok, _} = CredentialStore.get(as(@user), @reg, "stripe.com")
    end

    test "delete is idempotent" do
      assert :ok = CredentialStore.delete(as(@user), @reg, "never-existed")
    end
  end

  describe "multi-user privacy" do
    test "user B asking for user A's namespace gets :not_found, not A's token" do
      # User A holds a personal-namespace push token for "alice".
      put!(@user, @reg, "alice")

      # A user without their own credential must not receive another user's token.
      assert {:error, :not_found} = CredentialStore.get(as(@user2), @reg, "alice")
    end
  end

  describe "device_label/0" do
    # CYFR_DEVICE_LABEL reaches :cyfr, :device_label through runtime.exs's
    # Dotenvy pipeline; the module reads app config only, so the OS env is
    # not consulted here.
    setup do
      original_app = Application.get_env(:cyfr, :device_label)

      on_exit(fn ->
        if original_app,
          do: Application.put_env(:cyfr, :device_label, original_app),
          else: Application.delete_env(:cyfr, :device_label)
      end)

      :ok
    end

    test "reads :cyfr, :device_label" do
      Application.put_env(:cyfr, :device_label, "app-env-value")
      assert CredentialStore.device_label() == "app-env-value"
    end

    test "falls back to machine hostname when unset" do
      Application.delete_env(:cyfr, :device_label)

      label = CredentialStore.device_label()
      assert is_binary(label)
      assert label != ""
    end
  end
end
