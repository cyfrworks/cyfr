defmodule Sanctum.SecretsTest do
  use ExUnit.Case, async: false

  alias Sanctum.Secrets
  alias Sanctum.Context

  setup do
    # Use Arca.Repo sandbox for test isolation
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

    {:ok, ctx: Context.local()}
  end

  describe "set/3 and get/2" do
    test "stores and retrieves a secret", %{ctx: ctx} do
      assert :ok = Secrets.set(ctx, "API_KEY", "sk-secret123")
      assert {:ok, "sk-secret123"} = Secrets.get(ctx, "API_KEY")
    end

    test "overwrites existing secret", %{ctx: ctx} do
      assert :ok = Secrets.set(ctx, "API_KEY", "old-value")
      assert :ok = Secrets.set(ctx, "API_KEY", "new-value")
      assert {:ok, "new-value"} = Secrets.get(ctx, "API_KEY")
    end

    test "returns error for non-existent secret", %{ctx: ctx} do
      assert {:error, :not_found} = Secrets.get(ctx, "NONEXISTENT")
    end

    test "stores multiple secrets", %{ctx: ctx} do
      assert :ok = Secrets.set(ctx, "KEY1", "value1")
      assert :ok = Secrets.set(ctx, "KEY2", "value2")
      assert :ok = Secrets.set(ctx, "KEY3", "value3")

      assert {:ok, "value1"} = Secrets.get(ctx, "KEY1")
      assert {:ok, "value2"} = Secrets.get(ctx, "KEY2")
      assert {:ok, "value3"} = Secrets.get(ctx, "KEY3")
    end
  end

  describe "list/1" do
    test "returns empty list when no secrets exist", %{ctx: ctx} do
      assert {:ok, []} = Secrets.list(ctx)
    end

    test "returns sorted list of secret names", %{ctx: ctx} do
      Secrets.set(ctx, "ZEBRA", "z")
      Secrets.set(ctx, "ALPHA", "a")
      Secrets.set(ctx, "BETA", "b")

      assert {:ok, ["ALPHA", "BETA", "ZEBRA"]} = Secrets.list(ctx)
    end
  end

  describe "delete/2" do
    test "removes a secret", %{ctx: ctx} do
      Secrets.set(ctx, "API_KEY", "secret")
      assert {:ok, "secret"} = Secrets.get(ctx, "API_KEY")

      assert :ok = Secrets.delete(ctx, "API_KEY")
      assert {:error, :not_found} = Secrets.get(ctx, "API_KEY")
    end

    test "deleting non-existent secret succeeds", %{ctx: ctx} do
      assert :ok = Secrets.delete(ctx, "NONEXISTENT")
    end

    test "only removes specified secret", %{ctx: ctx} do
      Secrets.set(ctx, "KEY1", "value1")
      Secrets.set(ctx, "KEY2", "value2")

      Secrets.delete(ctx, "KEY1")

      assert {:error, :not_found} = Secrets.get(ctx, "KEY1")
      assert {:ok, "value2"} = Secrets.get(ctx, "KEY2")
    end
  end

  describe "exists?/2" do
    test "returns true for existing secret", %{ctx: ctx} do
      Secrets.set(ctx, "API_KEY", "secret")
      assert Secrets.exists?(ctx, "API_KEY")
    end

    test "returns false for non-existent secret", %{ctx: ctx} do
      refute Secrets.exists?(ctx, "NONEXISTENT")
    end

    test "returns false for invalid names", %{ctx: ctx} do
      refute Secrets.exists?(ctx, "")
      refute Secrets.exists?(ctx, "   ")
    end
  end

  describe "grant/3 and revoke/3" do
    test "grants component access to a secret", %{ctx: ctx} do
      Secrets.set(ctx, "API_KEY", "secret")

      assert :ok = Secrets.grant(ctx, "API_KEY", "catalyst:local.stripe-catalyst:1.0.0")
      assert {:ok, true} = Secrets.can_access?(ctx, "API_KEY", "catalyst:local.stripe-catalyst:1.0.0")
    end

    test "granting multiple times is idempotent", %{ctx: ctx} do
      Secrets.set(ctx, "API_KEY", "secret")

      assert :ok = Secrets.grant(ctx, "API_KEY", "catalyst:local.stripe-catalyst:1.0.0")
      assert :ok = Secrets.grant(ctx, "API_KEY", "catalyst:local.stripe-catalyst:1.0.0")

      {:ok, grants} = Secrets.list_grants(ctx, "API_KEY")
      assert length(grants) == 1
    end

    test "grants multiple components access", %{ctx: ctx} do
      Secrets.set(ctx, "API_KEY", "secret")

      Secrets.grant(ctx, "API_KEY", "catalyst:local.stripe-catalyst:1.0.0")
      Secrets.grant(ctx, "API_KEY", "catalyst:local.openai-catalyst:1.0.0")

      assert {:ok, true} = Secrets.can_access?(ctx, "API_KEY", "catalyst:local.stripe-catalyst:1.0.0")
      assert {:ok, true} = Secrets.can_access?(ctx, "API_KEY", "catalyst:local.openai-catalyst:1.0.0")
    end

    test "revokes component access", %{ctx: ctx} do
      Secrets.set(ctx, "API_KEY", "secret")
      Secrets.grant(ctx, "API_KEY", "catalyst:local.stripe-catalyst:1.0.0")

      assert {:ok, true} = Secrets.can_access?(ctx, "API_KEY", "catalyst:local.stripe-catalyst:1.0.0")

      assert {:ok, :revoked} = Secrets.revoke(ctx, "API_KEY", "catalyst:local.stripe-catalyst:1.0.0")
      assert {:ok, false} = Secrets.can_access?(ctx, "API_KEY", "catalyst:local.stripe-catalyst:1.0.0")
    end

    test "revoking non-granted component returns not_granted", %{ctx: ctx} do
      assert {:ok, :not_granted} = Secrets.revoke(ctx, "API_KEY", "catalyst:local.nonexistent-component:1.0.0")
    end

    test "grant rejects empty component ref", %{ctx: ctx} do
      assert {:error, _} = Secrets.grant(ctx, "API_KEY", "")
      assert {:error, _} = Secrets.grant(ctx, "API_KEY", "   ")
    end

    test "revoke rejects empty component ref", %{ctx: ctx} do
      assert {:error, _} = Secrets.revoke(ctx, "API_KEY", "")
    end
  end

  describe "list_grants/2" do
    test "returns empty list when no grants exist", %{ctx: ctx} do
      assert {:ok, []} = Secrets.list_grants(ctx, "API_KEY")
    end

    test "returns list of granted components", %{ctx: ctx} do
      Secrets.set(ctx, "API_KEY", "secret")
      Secrets.grant(ctx, "API_KEY", "catalyst:local.comp1:1.0.0")
      Secrets.grant(ctx, "API_KEY", "catalyst:local.comp2:1.0.0")

      {:ok, grants} = Secrets.list_grants(ctx, "API_KEY")
      assert length(grants) == 2
      assert "catalyst:local.comp1:1.0.0" in grants
      assert "catalyst:local.comp2:1.0.0" in grants
    end
  end

  describe "can_access?/3" do
    test "returns {:ok, false} for non-granted component", %{ctx: ctx} do
      Secrets.set(ctx, "API_KEY", "secret")
      assert {:ok, false} = Secrets.can_access?(ctx, "API_KEY", "catalyst:local.unauthorized:1.0.0")
    end

    test "returns {:ok, false} for non-existent secret", %{ctx: ctx} do
      assert {:ok, false} = Secrets.can_access?(ctx, "NONEXISTENT", "catalyst:local.any:1.0.0")
    end
  end

  describe "encryption at rest" do
    test "secret values are encrypted in the database", %{ctx: ctx} do
      Secrets.set(ctx, "SENSITIVE", "super_secret_value")

      # Read raw encrypted_value directly from the DB
      import Ecto.Query

      row =
        Arca.Repo.one(
          from(s in "secrets",
            where: s.name == "SENSITIVE",
            select: s.encrypted_value
          )
        )

      assert is_binary(row)
      # Raw DB value should NOT contain the plaintext
      refute String.contains?(row, "super_secret_value")
    end

    test "grant metadata is stored in plaintext (queryable)", %{ctx: ctx} do
      Secrets.grant(ctx, "API_KEY", "catalyst:local.stripe-catalyst:1.0.0")

      import Ecto.Query

      row =
        Arca.Repo.one(
          from(g in "secret_grants",
            where: g.secret_name == "API_KEY" and g.component_ref == "catalyst:local.stripe-catalyst:1.0.0",
            select: %{secret_name: g.secret_name, component_ref: g.component_ref}
          )
        )

      assert row.secret_name == "API_KEY"
      assert row.component_ref == "catalyst:local.stripe-catalyst:1.0.0"
    end
  end

  describe "org-scoped secrets" do
    test "org secrets are isolated from personal secrets", %{ctx: _ctx} do
      personal_ctx = Context.local()

      org_ctx = %Context{
        user_id: "user_123",
        org_id: "org_abc",
        permissions: MapSet.new([:*]),
        scope: :org,
        auth_method: :oidc,
        api_key_type: nil,
        request_id: nil,
        session_id: nil
      }

      # Set same key name in both contexts
      assert :ok = Secrets.set(personal_ctx, "API_KEY", "personal_value")
      assert :ok = Secrets.set(org_ctx, "API_KEY", "org_value")

      # Values should be different based on context
      assert {:ok, "personal_value"} = Secrets.get(personal_ctx, "API_KEY")
      assert {:ok, "org_value"} = Secrets.get(org_ctx, "API_KEY")
    end

    test "different orgs have isolated secrets" do
      org1_ctx = %Context{
        user_id: "user_123",
        org_id: "org_one",
        permissions: MapSet.new([:*]),
        scope: :org,
        auth_method: :oidc,
        api_key_type: nil,
        request_id: nil,
        session_id: nil
      }

      org2_ctx = %Context{
        user_id: "user_123",
        org_id: "org_two",
        permissions: MapSet.new([:*]),
        scope: :org,
        auth_method: :oidc,
        api_key_type: nil,
        request_id: nil,
        session_id: nil
      }

      assert :ok = Secrets.set(org1_ctx, "SHARED_KEY", "org1_secret")
      assert :ok = Secrets.set(org2_ctx, "SHARED_KEY", "org2_secret")

      assert {:ok, "org1_secret"} = Secrets.get(org1_ctx, "SHARED_KEY")
      assert {:ok, "org2_secret"} = Secrets.get(org2_ctx, "SHARED_KEY")
    end

    test "grants are isolated per org" do
      org1_ctx = %Context{
        user_id: "user_123",
        org_id: "org_one",
        permissions: MapSet.new([:*]),
        scope: :org,
        auth_method: :oidc,
        api_key_type: nil,
        request_id: nil,
        session_id: nil
      }

      org2_ctx = %Context{
        user_id: "user_123",
        org_id: "org_two",
        permissions: MapSet.new([:*]),
        scope: :org,
        auth_method: :oidc,
        api_key_type: nil,
        request_id: nil,
        session_id: nil
      }

      # Grant in org1 only
      assert :ok = Secrets.grant(org1_ctx, "API_KEY", "catalyst:local.component:1.0.0")

      # Only org1 should have the grant
      assert {:ok, true} = Secrets.can_access?(org1_ctx, "API_KEY", "catalyst:local.component:1.0.0")
      assert {:ok, false} = Secrets.can_access?(org2_ctx, "API_KEY", "catalyst:local.component:1.0.0")
    end
  end

  describe "secret name validation" do
    test "empty string name is rejected", %{ctx: ctx} do
      assert {:error, :invalid_name} = Secrets.set(ctx, "", "value_for_empty")
      assert {:error, :invalid_name} = Secrets.get(ctx, "")
    end

    test "whitespace-only name is rejected", %{ctx: ctx} do
      assert {:error, :invalid_name} = Secrets.set(ctx, "   ", "whitespace_value")
      assert {:error, :invalid_name} = Secrets.get(ctx, "   ")
      assert {:error, :invalid_name} = Secrets.delete(ctx, "\t\n")
    end

    test "special characters in name are allowed", %{ctx: ctx} do
      assert :ok = Secrets.set(ctx, "my-key.with/special:chars", "special_value")
      assert {:ok, "special_value"} = Secrets.get(ctx, "my-key.with/special:chars")
    end

    test "unicode names are supported", %{ctx: ctx} do
      assert :ok = Secrets.set(ctx, "秘密_キー_🔐", "unicode_value")
      assert {:ok, "unicode_value"} = Secrets.get(ctx, "秘密_キー_🔐")
    end

    test "very long name is supported", %{ctx: ctx} do
      long_name = String.duplicate("A", 1000)
      assert :ok = Secrets.set(ctx, long_name, "long_name_value")
      assert {:ok, "long_name_value"} = Secrets.get(ctx, long_name)
    end

    test "name with leading/trailing whitespace is normalized", %{ctx: ctx} do
      # Leading/trailing whitespace is trimmed (normalized)
      assert :ok = Secrets.set(ctx, "  KEY  ", "padded_value")
      # Can retrieve with original padded name
      assert {:ok, "padded_value"} = Secrets.get(ctx, "  KEY  ")
      # Can also retrieve with trimmed name (they're the same)
      assert {:ok, "padded_value"} = Secrets.get(ctx, "KEY")
      # Listing shows the normalized name
      {:ok, names} = Secrets.list(ctx)
      assert "KEY" in names
      refute "  KEY  " in names
    end

    test "grant rejects invalid secret names", %{ctx: ctx} do
      assert {:error, :invalid_name} = Secrets.grant(ctx, "", "catalyst:local.component:1.0.0")
      assert {:error, :invalid_name} = Secrets.grant(ctx, "   ", "catalyst:local.component:1.0.0")
    end

    test "list_grants rejects invalid secret names", %{ctx: ctx} do
      assert {:error, :invalid_name} = Secrets.list_grants(ctx, "")
    end
  end

  describe "resolve_granted_secrets/2" do
    test "resolves granted secrets for a component", %{ctx: ctx} do
      Secrets.set(ctx, "KEY1", "value1")
      Secrets.set(ctx, "KEY2", "value2")
      Secrets.set(ctx, "KEY3", "value3")

      Secrets.grant(ctx, "KEY1", "catalyst:local.my-component:1.0.0")
      Secrets.grant(ctx, "KEY2", "catalyst:local.my-component:1.0.0")
      # KEY3 not granted

      {:ok, %{secrets: secrets, failed: failed}} = Secrets.resolve_granted_secrets(ctx, "catalyst:local.my-component:1.0.0")

      assert secrets["KEY1"] == "value1"
      assert secrets["KEY2"] == "value2"
      refute Map.has_key?(secrets, "KEY3")
      assert failed == []
    end

    test "returns empty map when no grants exist", %{ctx: ctx} do
      {:ok, %{secrets: secrets, failed: failed}} = Secrets.resolve_granted_secrets(ctx, "catalyst:local.no-grants:1.0.0")
      assert secrets == %{}
      assert failed == []
    end
  end

  describe "key derivation" do
    test "set and get work with configured key base", %{ctx: ctx} do
      assert :ok = Secrets.set(ctx, "TEST_KEY", "test_value")
      assert {:ok, "test_value"} = Secrets.get(ctx, "TEST_KEY")
    end

    test "key derivation is consistent across calls", %{ctx: ctx} do
      assert :ok = Secrets.set(ctx, "CONSISTENCY_KEY", "value1")
      assert :ok = Secrets.set(ctx, "CONSISTENCY_KEY2", "value2")
      assert {:ok, "value1"} = Secrets.get(ctx, "CONSISTENCY_KEY")
      assert {:ok, "value2"} = Secrets.get(ctx, "CONSISTENCY_KEY2")
    end
  end

  describe "org_id validation" do
    test "scope :org with nil org_id raises ArgumentError" do
      nil_org_ctx = %Context{
        user_id: "user_123",
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :org,
        auth_method: :oidc,
        api_key_type: nil,
        request_id: nil,
        session_id: nil
      }

      assert_raise ArgumentError, ~r/org_id cannot be nil when scope is :org/, fn ->
        Secrets.set(nil_org_ctx, "KEY", "value")
      end

      assert_raise ArgumentError, ~r/org_id cannot be nil when scope is :org/, fn ->
        Secrets.get(nil_org_ctx, "KEY")
      end

      assert_raise ArgumentError, ~r/org_id cannot be nil when scope is :org/, fn ->
        Secrets.grant(nil_org_ctx, "KEY", "catalyst:local.component:1.0.0")
      end
    end

    test "scope :personal with nil org_id works fine", %{ctx: ctx} do
      # Personal scope doesn't require org_id
      assert ctx.scope == :personal
      assert is_nil(ctx.org_id)

      assert :ok = Secrets.set(ctx, "PERSONAL_KEY", "personal_value")
      assert {:ok, "personal_value"} = Secrets.get(ctx, "PERSONAL_KEY")
    end
  end

  describe "data integrity" do
    test "sequential writes don't lose data", %{ctx: ctx} do
      for i <- 1..10 do
        value = "value_#{i}"
        assert :ok = Secrets.set(ctx, "KEY", value)
        assert {:ok, ^value} = Secrets.get(ctx, "KEY")
      end
    end

    test "writes to different keys are preserved", %{ctx: ctx} do
      for i <- 1..10 do
        key = "KEY_#{i}"
        value = "value_#{i}"
        assert :ok = Secrets.set(ctx, key, value)
      end

      for i <- 1..10 do
        key = "KEY_#{i}"
        expected_value = "value_#{i}"
        assert {:ok, ^expected_value} = Secrets.get(ctx, key)
      end
    end

    test "many set/delete operations maintain consistency", %{ctx: ctx} do
      for i <- 1..50 do
        key = "STRESS_#{i}"
        assert :ok = Secrets.set(ctx, key, "value")
      end

      for i <- 1..25 do
        key = "STRESS_#{i}"
        assert :ok = Secrets.delete(ctx, key)
      end

      {:ok, keys} = Secrets.list(ctx)
      assert length(keys) == 25

      for i <- 26..50 do
        key = "STRESS_#{i}"
        assert {:ok, "value"} = Secrets.get(ctx, key)
      end
    end
  end
end
