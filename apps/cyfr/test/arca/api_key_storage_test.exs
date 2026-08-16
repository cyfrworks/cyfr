# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ApiKeyStorageTest do
  use ExUnit.Case, async: false

  alias Arca.ApiKeyStorage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()

    {:ok, athanor_id: ctx.athanor_id}
  end

  defp key_attrs(name, athanor_id, overrides \\ %{}) do
    hash = :crypto.hash(:sha256, "key_#{name}_#{:rand.uniform(100_000)}")

    Map.merge(
      %{
        name: name,
        key_hash: hash,
        key_prefix: "cyfr_sk_test",
        type: "secret",
        scope: "[]",
        athanor_id: athanor_id,
        created_by: "test_user"
      },
      overrides
    )
  end

  describe "create_key/1 and get_key/2" do
    test "stores and retrieves a key", %{athanor_id: athanor_id} do
      attrs = key_attrs("test-key", athanor_id)
      assert :ok = ApiKeyStorage.create_key(attrs)

      assert {:ok, key} = ApiKeyStorage.get_key("test-key", athanor_id)
      assert key.name == "test-key"
      assert key.type == "secret"
      assert key.revoked == false
    end

    test "returns not_found for missing key", %{athanor_id: athanor_id} do
      assert {:error, :not_found} = ApiKeyStorage.get_key("missing", athanor_id)
    end

    test "duplicate name returns already_exists", %{athanor_id: athanor_id} do
      attrs = key_attrs("dup-key", athanor_id)
      :ok = ApiKeyStorage.create_key(attrs)

      assert {:error, :already_exists} = ApiKeyStorage.create_key(attrs)
    end
  end

  describe "get_key_by_hash/1" do
    test "retrieves key by hash", %{athanor_id: athanor_id} do
      attrs = key_attrs("hash-key", athanor_id)
      :ok = ApiKeyStorage.create_key(attrs)

      assert {:ok, key} = ApiKeyStorage.get_key_by_hash(attrs.key_hash)
      assert key.name == "hash-key"
    end

    test "returns not_found for unknown hash" do
      unknown_hash = :crypto.hash(:sha256, "unknown_key")
      assert {:error, :not_found} = ApiKeyStorage.get_key_by_hash(unknown_hash)
    end
  end

  describe "list_keys/2" do
    test "lists non-revoked keys", %{athanor_id: athanor_id} do
      :ok = ApiKeyStorage.create_key(key_attrs("list-a", athanor_id))
      :ok = ApiKeyStorage.create_key(key_attrs("list-b", athanor_id))

      {:ok, keys} = ApiKeyStorage.list_keys(athanor_id)
      names = Enum.map(keys, & &1.name)
      assert "list-a" in names
      assert "list-b" in names
    end

    test "returns empty list when no keys", %{athanor_id: athanor_id} do
      {:ok, keys} = ApiKeyStorage.list_keys("ath_empty")
      assert keys == []
    end
  end

  describe "revoke_key/3" do
    test "revokes a key so it's no longer retrievable", %{athanor_id: athanor_id} do
      :ok = ApiKeyStorage.create_key(key_attrs("revoke-me", athanor_id))

      assert :ok = ApiKeyStorage.revoke_key("revoke-me", athanor_id)
      assert {:error, :not_found} = ApiKeyStorage.get_key("revoke-me", athanor_id)
    end

    test "returns not_found for missing key", %{athanor_id: athanor_id} do
      assert {:error, :not_found} = ApiKeyStorage.revoke_key("nope", athanor_id)
    end

    test "revoked key excluded from list", %{athanor_id: athanor_id} do
      :ok = ApiKeyStorage.create_key(key_attrs("revoke-list", athanor_id))
      :ok = ApiKeyStorage.revoke_key("revoke-list", athanor_id)

      {:ok, keys} = ApiKeyStorage.list_keys(athanor_id)
      refute Enum.any?(keys, &(&1.name == "revoke-list"))
    end
  end

  describe "rotate_key/4" do
    test "updates hash and prefix", %{athanor_id: athanor_id} do
      :ok = ApiKeyStorage.create_key(key_attrs("rotate-me", athanor_id))

      new_hash = :crypto.hash(:sha256, "rotated_key")
      new_prefix = "cyfr_sk_rotated"

      assert :ok =
               ApiKeyStorage.rotate_key("rotate-me", athanor_id, new_hash, new_prefix)

      {:ok, key} = ApiKeyStorage.get_key_by_hash(new_hash)
      assert key.name == "rotate-me"
      assert key.key_prefix == new_prefix
    end

    test "returns not_found for missing key", %{athanor_id: athanor_id} do
      new_hash = :crypto.hash(:sha256, "nope")

      assert {:error, :not_found} =
               ApiKeyStorage.rotate_key("nope", athanor_id, new_hash, "pfx")
    end
  end

  describe "tenant isolation" do
    test "different athanors cannot see each other's keys" do
      :ok = ApiKeyStorage.create_key(key_attrs("shared-name", "ath_alpha"))
      :ok = ApiKeyStorage.create_key(key_attrs("shared-name", "ath_beta"))

      {:ok, key_a} = ApiKeyStorage.get_key("shared-name", "ath_alpha")
      {:ok, key_b} = ApiKeyStorage.get_key("shared-name", "ath_beta")
      assert key_a.athanor_id != key_b.athanor_id

      {:ok, a_keys} = ApiKeyStorage.list_keys("ath_alpha")
      {:ok, b_keys} = ApiKeyStorage.list_keys("ath_beta")
      assert length(a_keys) == 1
      assert length(b_keys) == 1
    end

    # NOTE: there is no tenant-scoped hash lookup. API keys are athanor
    # credentials: a key is resolved by its globally-unique hash and its
    # athanor is read back from the row; the tenant binding is then enforced
    # on the resulting Sanctum.Context via require_tenant!/where_tenant
    # (covered by Arca.R6AthanorLessFailClosedTest and Sanctum.ApiKeyTest),
    # not by a tenant-scoped storage lookup.
  end
end
