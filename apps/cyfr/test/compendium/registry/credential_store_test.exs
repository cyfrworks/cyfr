defmodule Compendium.Registry.CredentialStoreTest do
  use ExUnit.Case, async: false

  alias Compendium.Registry.CredentialStore

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # Clean up any test credentials from prior runs
    CredentialStore.delete("test_user_1", "registry.test.com")
    CredentialStore.delete("test_user_2", "registry.test.com")
    CredentialStore.delete("test_user_1", "other.registry.com")

    :ok
  end

  describe "put/get" do
    test "stores and retrieves basic credentials" do
      cred = %{type: :basic, username: "user@test.com", password: "jwt_token_123"}
      assert :ok = CredentialStore.put("test_user_1", "registry.test.com", cred)

      assert {:ok, retrieved} = CredentialStore.get("test_user_1", "registry.test.com")
      assert retrieved.type == :basic
      assert retrieved.username == "user@test.com"
      assert retrieved.password == "jwt_token_123"
    end

    test "stores and retrieves bearer credentials" do
      cred = %{type: :bearer, token: "bearer_token_456"}
      assert :ok = CredentialStore.put("test_user_1", "registry.test.com", cred)

      assert {:ok, retrieved} = CredentialStore.get("test_user_1", "registry.test.com")
      assert retrieved.type == :bearer
      assert retrieved.token == "bearer_token_456"
    end

    test "stores and retrieves oauth2_client credentials" do
      cred = %{
        type: :oauth2_client,
        client_id: "my_client",
        client_secret: "my_secret",
        token_url: "https://auth.example.com/token"
      }

      assert :ok = CredentialStore.put("test_user_1", "registry.test.com", cred)

      assert {:ok, retrieved} = CredentialStore.get("test_user_1", "registry.test.com")
      assert retrieved.type == :oauth2_client
      assert retrieved.client_id == "my_client"
      assert retrieved.client_secret == "my_secret"
      assert retrieved.token_url == "https://auth.example.com/token"
    end

    test "overwrites existing credentials on put" do
      cred1 = %{type: :basic, username: "old@test.com", password: "old_token"}
      cred2 = %{type: :basic, username: "new@test.com", password: "new_token"}

      assert :ok = CredentialStore.put("test_user_1", "registry.test.com", cred1)
      assert :ok = CredentialStore.put("test_user_1", "registry.test.com", cred2)

      assert {:ok, retrieved} = CredentialStore.get("test_user_1", "registry.test.com")
      assert retrieved.username == "new@test.com"
      assert retrieved.password == "new_token"
    end

    test "returns :not_found for missing credentials" do
      assert :not_found = CredentialStore.get("nonexistent_user", "nonexistent.registry.com")
    end
  end

  describe "user isolation" do
    test "different users have separate credentials" do
      cred1 = %{type: :basic, username: "user1@test.com", password: "token1"}
      cred2 = %{type: :basic, username: "user2@test.com", password: "token2"}

      assert :ok = CredentialStore.put("test_user_1", "registry.test.com", cred1)
      assert :ok = CredentialStore.put("test_user_2", "registry.test.com", cred2)

      assert {:ok, r1} = CredentialStore.get("test_user_1", "registry.test.com")
      assert {:ok, r2} = CredentialStore.get("test_user_2", "registry.test.com")

      assert r1.username == "user1@test.com"
      assert r2.username == "user2@test.com"
    end

    test "different registries have separate credentials" do
      cred1 = %{type: :basic, username: "user@test.com", password: "token_reg1"}
      cred2 = %{type: :basic, username: "user@test.com", password: "token_reg2"}

      assert :ok = CredentialStore.put("test_user_1", "registry.test.com", cred1)
      assert :ok = CredentialStore.put("test_user_1", "other.registry.com", cred2)

      assert {:ok, r1} = CredentialStore.get("test_user_1", "registry.test.com")
      assert {:ok, r2} = CredentialStore.get("test_user_1", "other.registry.com")

      assert r1.password == "token_reg1"
      assert r2.password == "token_reg2"
    end
  end

  describe "get_for_registry" do
    test "finds any credential for a registry" do
      cred = %{type: :basic, username: "user@test.com", password: "jwt_token"}
      assert :ok = CredentialStore.put("test_user_1", "registry.test.com", cred)

      assert {:ok, retrieved} = CredentialStore.get_for_registry("registry.test.com")
      assert retrieved.type == :basic
      assert retrieved.username == "user@test.com"
    end

    test "returns :not_found when no credentials exist" do
      assert :not_found = CredentialStore.get_for_registry("nonexistent.registry.com")
    end
  end

  describe "delete" do
    test "removes credentials" do
      cred = %{type: :basic, username: "user@test.com", password: "jwt_token"}
      assert :ok = CredentialStore.put("test_user_1", "registry.test.com", cred)

      assert {:ok, _} = CredentialStore.get("test_user_1", "registry.test.com")

      assert :ok = CredentialStore.delete("test_user_1", "registry.test.com")
      assert :not_found = CredentialStore.get("test_user_1", "registry.test.com")
    end

    test "delete is idempotent" do
      assert :ok = CredentialStore.delete("test_user_1", "nonexistent.registry.com")
    end
  end
end
