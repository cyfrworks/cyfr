defmodule Arca.ApiKeyStorageTest do
  use ExUnit.Case, async: false

  alias Arca.ApiKeyStorage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.Context.local()
    org_id = ctx.org_id

    {:ok, org_id: org_id}
  end

  defp key_attrs(name, org_id, overrides \\ %{}) do
    hash = :crypto.hash(:sha256, "key_#{name}_#{:rand.uniform(100_000)}")

    Map.merge(
      %{
        name: name,
        key_hash: hash,
        key_prefix: "cyfr_sk_test",
        type: "secret",
        scope: "[]",
        scope_type: "project",
        org_id: org_id,
        created_by: "test_user"
      },
      overrides
    )
  end

  describe "create_key/1 and get_key/3" do
    test "stores and retrieves a key", %{org_id: org_id} do
      attrs = key_attrs("test-key", org_id)
      assert :ok = ApiKeyStorage.create_key(attrs)

      assert {:ok, key} = ApiKeyStorage.get_key("test-key", "project", org_id)
      assert key.name == "test-key"
      assert key.type == "secret"
      assert key.revoked == false
    end

    test "returns not_found for missing key", %{org_id: org_id} do
      assert {:error, :not_found} = ApiKeyStorage.get_key("missing", "project", org_id)
    end

    test "duplicate name returns already_exists", %{org_id: org_id} do
      attrs = key_attrs("dup-key", org_id)
      :ok = ApiKeyStorage.create_key(attrs)

      assert {:error, :already_exists} = ApiKeyStorage.create_key(attrs)
    end
  end

  describe "get_key_by_hash/1" do
    test "retrieves key by hash", %{org_id: org_id} do
      attrs = key_attrs("hash-key", org_id)
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
    test "lists non-revoked keys", %{org_id: org_id} do
      :ok = ApiKeyStorage.create_key(key_attrs("list-a", org_id))
      :ok = ApiKeyStorage.create_key(key_attrs("list-b", org_id))

      {:ok, keys} = ApiKeyStorage.list_keys("project", org_id)
      names = Enum.map(keys, & &1.name)
      assert "list-a" in names
      assert "list-b" in names
    end

    test "returns empty list when no keys", %{org_id: org_id} do
      {:ok, keys} = ApiKeyStorage.list_keys("empty_scope", org_id)
      assert keys == []
    end
  end

  describe "revoke_key/3" do
    test "revokes a key so it's no longer retrievable", %{org_id: org_id} do
      :ok = ApiKeyStorage.create_key(key_attrs("revoke-me", org_id))

      assert :ok = ApiKeyStorage.revoke_key("revoke-me", "project", org_id)
      assert {:error, :not_found} = ApiKeyStorage.get_key("revoke-me", "project", org_id)
    end

    test "returns not_found for missing key", %{org_id: org_id} do
      assert {:error, :not_found} = ApiKeyStorage.revoke_key("nope", "project", org_id)
    end

    test "revoked key excluded from list", %{org_id: org_id} do
      :ok = ApiKeyStorage.create_key(key_attrs("revoke-list", org_id))
      :ok = ApiKeyStorage.revoke_key("revoke-list", "project", org_id)

      {:ok, keys} = ApiKeyStorage.list_keys("project", org_id)
      refute Enum.any?(keys, &(&1.name == "revoke-list"))
    end
  end

  describe "rotate_key/5" do
    test "updates hash and prefix", %{org_id: org_id} do
      :ok = ApiKeyStorage.create_key(key_attrs("rotate-me", org_id))

      new_hash = :crypto.hash(:sha256, "rotated_key")
      new_prefix = "cyfr_sk_rotated"

      assert :ok = ApiKeyStorage.rotate_key("rotate-me", "project", org_id, new_hash, new_prefix)

      {:ok, key} = ApiKeyStorage.get_key_by_hash(new_hash)
      assert key.name == "rotate-me"
      assert key.key_prefix == new_prefix
    end

    test "returns not_found for missing key", %{org_id: org_id} do
      new_hash = :crypto.hash(:sha256, "nope")
      assert {:error, :not_found} = ApiKeyStorage.rotate_key("nope", "project", org_id, new_hash, "pfx")
    end
  end

  describe "tenant isolation" do
    test "different org_ids cannot see each other's keys" do
      :ok = ApiKeyStorage.create_key(key_attrs("shared-name", "org_alpha"))
      :ok = ApiKeyStorage.create_key(key_attrs("shared-name", "org_beta"))

      {:ok, key_a} = ApiKeyStorage.get_key("shared-name", "project", "org_alpha")
      {:ok, key_b} = ApiKeyStorage.get_key("shared-name", "project", "org_beta")
      assert key_a.org_id != key_b.org_id

      {:ok, a_keys} = ApiKeyStorage.list_keys("project", "org_alpha")
      {:ok, b_keys} = ApiKeyStorage.list_keys("project", "org_beta")
      assert length(a_keys) == 1
      assert length(b_keys) == 1
    end

    test "get_key_by_hash/2 enforces org_id isolation" do
      attrs_a = key_attrs("org-a-key", "org_alpha")
      attrs_b = key_attrs("org-b-key", "org_beta")
      :ok = ApiKeyStorage.create_key(attrs_a)
      :ok = ApiKeyStorage.create_key(attrs_b)

      # Key A is found when org matches
      assert {:ok, key} = ApiKeyStorage.get_key_by_hash(attrs_a.key_hash, "org_alpha")
      assert key.name == "org-a-key"

      # Key A is NOT found when queried against org B
      assert {:error, :not_found} = ApiKeyStorage.get_key_by_hash(attrs_a.key_hash, "org_beta")

      # Key B is NOT found when queried against org A
      assert {:error, :not_found} = ApiKeyStorage.get_key_by_hash(attrs_b.key_hash, "org_alpha")

      # Arity-1 version still works (global lookup)
      assert {:ok, _} = ApiKeyStorage.get_key_by_hash(attrs_a.key_hash)
      assert {:ok, _} = ApiKeyStorage.get_key_by_hash(attrs_b.key_hash)
    end
  end
end
