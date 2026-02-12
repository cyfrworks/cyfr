defmodule Sanctum.AtomsTest do
  use ExUnit.Case, async: true

  alias Sanctum.Atoms

  describe "safe_to_atom/1" do
    test "converts known permission strings to atoms" do
      assert Atoms.safe_to_atom("execute") == :execute
      assert Atoms.safe_to_atom("read") == :read
      assert Atoms.safe_to_atom("write") == :write
      assert Atoms.safe_to_atom("admin") == :admin
    end

    test "converts known provider strings to atoms" do
      assert Atoms.safe_to_atom("github") == :github
      assert Atoms.safe_to_atom("google") == :google
      assert Atoms.safe_to_atom("okta") == :okta
      assert Atoms.safe_to_atom("azure") == :azure
      assert Atoms.safe_to_atom("local") == :local
      assert Atoms.safe_to_atom("oidc") == :oidc
    end

    test "converts known scope strings to atoms" do
      assert Atoms.safe_to_atom("personal") == :personal
      assert Atoms.safe_to_atom("org") == :org
    end

    test "returns unknown strings as-is to prevent atom table exhaustion" do
      assert Atoms.safe_to_atom("unknown_malicious_string") == "unknown_malicious_string"
      assert Atoms.safe_to_atom("arbitrary_user_input_12345") == "arbitrary_user_input_12345"
    end

    test "passes through existing atoms unchanged" do
      assert Atoms.safe_to_atom(:execute) == :execute
      assert Atoms.safe_to_atom(:custom_atom) == :custom_atom
    end

    test "returns non-string, non-atom values unchanged" do
      assert Atoms.safe_to_atom(123) == 123
      assert Atoms.safe_to_atom(nil) == nil
      assert Atoms.safe_to_atom(%{key: "value"}) == %{key: "value"}
    end

    test "converts existing atoms from string form" do
      # Create the atom first so it exists
      _ = :existing_test_atom

      # Now safe_to_atom should find it via String.to_existing_atom
      assert Atoms.safe_to_atom("existing_test_atom") == :existing_test_atom
    end
  end

  describe "safe_to_permission_atom/1" do
    test "converts known permission strings to atoms" do
      assert Atoms.safe_to_permission_atom("execute") == :execute
      assert Atoms.safe_to_permission_atom("read") == :read
      assert Atoms.safe_to_permission_atom("write") == :write
      assert Atoms.safe_to_permission_atom("admin") == :admin
      assert Atoms.safe_to_permission_atom("publish") == :publish
      assert Atoms.safe_to_permission_atom("build") == :build
      assert Atoms.safe_to_permission_atom("search") == :search
      assert Atoms.safe_to_permission_atom("audit") == :audit
      assert Atoms.safe_to_permission_atom("secret_access") == :secret_access
    end

    test "returns unknown permission strings as-is" do
      # Completely unknown strings should not be converted
      assert Atoms.safe_to_permission_atom("unknown_permission_xyz123") == "unknown_permission_xyz123"
      assert Atoms.safe_to_permission_atom("malicious_input_attempt") == "malicious_input_attempt"
    end

    test "passes through existing atoms unchanged" do
      assert Atoms.safe_to_permission_atom(:execute) == :execute
      assert Atoms.safe_to_permission_atom(:custom) == :custom
    end

    test "may return existing atoms even if not in permission allowlist" do
      # Note: String.to_existing_atom finds atoms that already exist in the VM
      # So "github" might return :github if the atom exists from other code
      # This is expected behavior - the function is safe because it won't
      # create NEW atoms for unknown strings
      result = Atoms.safe_to_permission_atom("github")
      # Either returns the existing atom or the string, both are safe
      assert result == :github or result == "github"
    end
  end

  describe "safe_to_provider_atom/1" do
    test "converts known provider strings to atoms" do
      assert Atoms.safe_to_provider_atom("github") == :github
      assert Atoms.safe_to_provider_atom("google") == :google
      assert Atoms.safe_to_provider_atom("okta") == :okta
      assert Atoms.safe_to_provider_atom("azure") == :azure
      assert Atoms.safe_to_provider_atom("local") == :local
      assert Atoms.safe_to_provider_atom("oidc") == :oidc
    end

    test "returns unknown provider strings as-is" do
      # Completely unknown strings should not be converted
      assert Atoms.safe_to_provider_atom("unknown_provider_xyz123") == "unknown_provider_xyz123"
      assert Atoms.safe_to_provider_atom("malicious_provider_input") == "malicious_provider_input"
    end

    test "passes through existing atoms unchanged" do
      assert Atoms.safe_to_provider_atom(:github) == :github
      assert Atoms.safe_to_provider_atom(:custom_provider) == :custom_provider
    end

    test "may return existing atoms even if not in provider allowlist" do
      # Note: String.to_existing_atom finds atoms that already exist in the VM
      # So "execute" might return :execute if the atom exists from other code
      # This is expected behavior - the function is safe because it won't
      # create NEW atoms for unknown strings
      result = Atoms.safe_to_provider_atom("execute")
      # Either returns the existing atom or the string, both are safe
      assert result == :execute or result == "execute"
    end
  end

  describe "security: atom table exhaustion prevention" do
    test "does not create atoms for random strings" do
      # Generate random strings that should not become atoms
      random_strings = for _ <- 1..100 do
        :crypto.strong_rand_bytes(16) |> Base.encode16()
      end

      results = Enum.map(random_strings, &Atoms.safe_to_atom/1)

      # All results should be the original strings, not atoms
      for {result, original} <- Enum.zip(results, random_strings) do
        assert is_binary(result), "Expected string, got: #{inspect(result)}"
        assert result == original
      end
    end
  end
end
