defmodule Opus.SecretsWasiTest do
  @moduledoc """
  Tests for the WASI secrets interface (cyfr:secrets/read).

  These tests verify that:
  1. The secrets imports are correctly built with context
  2. Access control is enforced at the WASI level
  3. Secret values are properly returned to granted components

  Note: Full integration tests with actual WASM components that call
  cyfr:secrets/read would require building test WASM components.
  These tests focus on the host-side implementation.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.Secrets

  setup do
    # Use Arca.Repo sandbox for test isolation
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

    {:ok, ctx: Context.local()}
  end

  describe "secrets access control" do
    test "component can access granted secret", %{ctx: ctx} do
      # Set up a secret and grant access
      :ok = Secrets.set(ctx, "TEST_API_KEY", "sk-test123")
      :ok = Secrets.grant(ctx, "TEST_API_KEY", "local.test-component:1.0.0")

      # Verify access check works
      assert {:ok, true} = Secrets.can_access?(ctx, "TEST_API_KEY", "local.test-component:1.0.0")

      # Verify secret can be retrieved
      assert {:ok, "sk-test123"} = Secrets.get(ctx, "TEST_API_KEY")
    end

    test "component cannot access ungranted secret", %{ctx: ctx} do
      # Set up a secret but don't grant access
      :ok = Secrets.set(ctx, "PRIVATE_KEY", "secret-value")

      # Verify access check fails
      assert {:ok, false} = Secrets.can_access?(ctx, "PRIVATE_KEY", "local.test-component:1.0.0")
    end

    test "access check returns false for non-existent secret", %{ctx: ctx} do
      assert {:ok, false} = Secrets.can_access?(ctx, "NONEXISTENT", "local.test-component:1.0.0")
    end

    test "revoked access is properly enforced", %{ctx: ctx} do
      # Set up a secret, grant, then revoke
      :ok = Secrets.set(ctx, "REVOKE_TEST", "value")
      :ok = Secrets.grant(ctx, "REVOKE_TEST", "local.test-component:1.0.0")

      # Verify access works initially
      assert {:ok, true} = Secrets.can_access?(ctx, "REVOKE_TEST", "local.test-component:1.0.0")

      # Revoke access
      {:ok, :revoked} = Secrets.revoke(ctx, "REVOKE_TEST", "local.test-component:1.0.0")

      # Verify access is now denied
      assert {:ok, false} = Secrets.can_access?(ctx, "REVOKE_TEST", "local.test-component:1.0.0")
    end
  end

  describe "SecretMasker" do
    alias Opus.SecretMasker

    test "get_granted_secrets returns empty list for nil context" do
      assert [] = SecretMasker.get_granted_secrets(nil, "local.component:1.0.0")
    end

    test "get_granted_secrets returns empty list for nil component_ref", %{ctx: ctx} do
      assert [] = SecretMasker.get_granted_secrets(ctx, nil)
    end

    test "get_granted_secrets returns secret values for granted secrets", %{ctx: ctx} do
      # Set up secrets
      :ok = Secrets.set(ctx, "KEY1", "value1")
      :ok = Secrets.set(ctx, "KEY2", "value2")
      :ok = Secrets.set(ctx, "KEY3", "value3")

      # Grant access to KEY1 and KEY2 only
      :ok = Secrets.grant(ctx, "KEY1", "local.my-component:1.0.0")
      :ok = Secrets.grant(ctx, "KEY2", "local.my-component:1.0.0")

      secrets = SecretMasker.get_granted_secrets(ctx, "local.my-component:1.0.0")

      assert "value1" in secrets
      assert "value2" in secrets
      refute "value3" in secrets
    end

    test "mask replaces secret values with [REDACTED]" do
      output = %{"message" => "Your API key is sk-secret123", "data" => "other"}
      masked = SecretMasker.mask(output, ["sk-secret123"])

      assert masked["message"] == "Your API key is [REDACTED]"
      assert masked["data"] == "other"
    end

    test "mask handles nested maps" do
      output = %{
        "result" => %{
          "nested" => "contains sk-secret123 value"
        }
      }
      masked = SecretMasker.mask(output, ["sk-secret123"])

      assert masked["result"]["nested"] == "contains [REDACTED] value"
    end

    test "mask handles lists" do
      output = ["sk-secret123", "normal", "another sk-secret123"]
      masked = SecretMasker.mask(output, ["sk-secret123"])

      assert masked == ["[REDACTED]", "normal", "another [REDACTED]"]
    end

    test "mask returns output unchanged when no secrets to mask" do
      output = %{"data" => "no secrets here"}
      assert output == SecretMasker.mask(output, [])
    end

    test "mask ignores short secrets (less than 4 chars)" do
      # Short secrets are not masked to avoid false positives
      output = %{"data" => "abc is short"}
      masked = SecretMasker.mask(output, ["abc"])

      assert masked["data"] == "abc is short"
    end

    test "mask handles multiple secrets" do
      output = %{"message" => "key1: secret1, key2: secret2"}
      masked = SecretMasker.mask(output, ["secret1", "secret2"])

      assert masked["message"] == "key1: [REDACTED], key2: [REDACTED]"
    end

    test "mask handles binary strings" do
      output = "plain text with secret123 in it"
      masked = SecretMasker.mask(output, ["secret123"])

      assert masked == "plain text with [REDACTED] in it"
    end

    test "mask detects base64-encoded secrets" do
      secret = "sk-test123"
      encoded = Base.encode64(secret)
      output = %{"data" => "encoded: #{encoded}"}
      masked = SecretMasker.mask(output, [secret])

      assert masked["data"] == "encoded: [REDACTED]"
    end

    test "mask detects url-safe base64-encoded secrets" do
      secret = "sk-test+key/value"
      encoded = Base.url_encode64(secret)
      output = %{"data" => "token=#{encoded}"}
      masked = SecretMasker.mask(output, [secret])

      assert masked["data"] == "token=[REDACTED]"
    end

    test "mask detects hex-encoded secrets (lowercase)" do
      secret = "sk-test123"
      hex = Base.encode16(secret, case: :lower)
      output = %{"data" => "hex: #{hex}"}
      masked = SecretMasker.mask(output, [secret])

      assert masked["data"] == "hex: [REDACTED]"
    end

    test "mask detects hex-encoded secrets (uppercase)" do
      secret = "sk-test123"
      hex = Base.encode16(secret, case: :upper)
      output = %{"data" => "hex: #{hex}"}
      masked = SecretMasker.mask(output, [secret])

      assert masked["data"] == "hex: [REDACTED]"
    end

    test "mask handles all encodings simultaneously" do
      secret = "api-key-456"
      b64 = Base.encode64(secret)
      hex = Base.encode16(secret, case: :lower)

      output = %{"b64" => b64, "hex" => hex, "plain" => secret}
      masked = SecretMasker.mask(output, [secret])

      assert masked["b64"] == "[REDACTED]"
      assert masked["hex"] == "[REDACTED]"
      assert masked["plain"] == "[REDACTED]"
    end
  end

  describe "Runtime secrets imports" do
    # These tests verify the secrets imports structure
    # Full integration tests would require WASM components

    test "secrets imports are built when context and component_ref provided", %{ctx: ctx} do
      # Set up a secret for the test
      :ok = Secrets.set(ctx, "RUNTIME_TEST", "test-value")
      :ok = Secrets.grant(ctx, "RUNTIME_TEST", "local.runtime-test:1.0.0")

      # The Runtime module builds imports internally, but we can verify
      # the access control works correctly
      assert {:ok, true} = Secrets.can_access?(ctx, "RUNTIME_TEST", "local.runtime-test:1.0.0")
      assert {:ok, "test-value"} = Secrets.get(ctx, "RUNTIME_TEST")
    end
  end

  describe "Reagent secret denial" do
    test "reagent component type does not receive secrets imports" do
      # Verify that build_start_opts_with_limits for non-catalyst types
      # produces no secrets imports, even when preloaded_secrets are present.
      # We test this indirectly by checking that the Runtime module gates
      # secrets to :catalyst only.

      preloaded = %{"API_KEY" => "secret-value"}
      component_ref = "local.test-reagent:1.0.0"

      # For a catalyst, secrets imports should be built
      catalyst_imports = Opus.Runtime.TestHelper.build_imports(:catalyst, preloaded, component_ref)
      assert Map.has_key?(catalyst_imports, "cyfr:secrets/read@0.1.0")

      # For a reagent, secrets imports should NOT be built
      reagent_imports = Opus.Runtime.TestHelper.build_imports(:reagent, preloaded, component_ref)
      refute Map.has_key?(reagent_imports, "cyfr:secrets/read@0.1.0")

      # For a formula, secrets imports should NOT be built
      formula_imports = Opus.Runtime.TestHelper.build_imports(:formula, preloaded, component_ref)
      refute Map.has_key?(formula_imports, "cyfr:secrets/read@0.1.0")
    end

    test "granted secret returns {:ok, value} tuple" do
      preloaded = %{"API_KEY" => "sk-test123"}
      component_ref = "local.test-catalyst:1.0.0"

      imports = Opus.Runtime.TestHelper.build_imports(:catalyst, preloaded, component_ref)
      {:fn, get_fn} = imports["cyfr:secrets/read@0.1.0"]["get"]

      assert {:ok, "sk-test123"} = get_fn.("API_KEY")
    end

    test "denied secret returns {:error, access-denied} tuple" do
      preloaded = %{"API_KEY" => "sk-test123"}
      component_ref = "local.test-catalyst:1.0.0"

      imports = Opus.Runtime.TestHelper.build_imports(:catalyst, preloaded, component_ref)
      {:fn, get_fn} = imports["cyfr:secrets/read@0.1.0"]["get"]

      assert {:error, msg} = get_fn.("MISSING_KEY")
      assert msg =~ "access-denied"
      assert msg =~ "MISSING_KEY"
      assert msg =~ component_ref
    end
  end
end
