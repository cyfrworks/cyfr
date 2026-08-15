# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.AtomsTest do
  use ExUnit.Case, async: true

  alias Sanctum.Atoms

  describe "safe_to_atom/1" do
    test "converts known permission strings to atoms" do
      assert Atoms.safe_to_atom("execute") == :execute
      assert Atoms.safe_to_atom("storage_read") == :storage_read
      assert Atoms.safe_to_atom("storage_write") == :storage_write
      assert Atoms.safe_to_atom("admin") == :admin
    end

    test "retired vocabulary stays a string even though its atoms exist in the VM" do
      # Membership-first conversion: :read/:write exist as atoms all over
      # the VM, but they are not permissions — resolving them here is what
      # let retired grant names keep round-tripping.
      assert Atoms.safe_to_atom("read") == "read"
      assert Atoms.safe_to_atom("write") == "write"
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
      assert Atoms.safe_to_atom("project") == :project
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

    test "an atom existing in the VM does not make its string convertible" do
      _ = :existing_test_atom

      # The allowlist is the list — not the VM's atom table.
      assert Atoms.safe_to_atom("existing_test_atom") == "existing_test_atom"
    end
  end

  describe "safe_to_permission_atom/1" do
    test "converts known permission strings to atoms" do
      for name <- Atoms.known_permissions() do
        assert Atoms.safe_to_permission_atom(name) == String.to_existing_atom(name)
      end
    end

    test "retired permission names come back as strings" do
      # These atoms all exist in the VM (old vocabulary, action verbs), but
      # none is a permission. A stored grant naming one silently drops.
      for retired <- ~w(read write publish build search audit secret_access) do
        assert Atoms.safe_to_permission_atom(retired) == retired
      end
    end

    test "returns unknown permission strings as-is" do
      # Completely unknown strings should not be converted
      assert Atoms.safe_to_permission_atom("unknown_permission_xyz123") ==
               "unknown_permission_xyz123"

      assert Atoms.safe_to_permission_atom("malicious_input_attempt") == "malicious_input_attempt"
    end

    test "passes through existing atoms unchanged" do
      assert Atoms.safe_to_permission_atom(:execute) == :execute
      assert Atoms.safe_to_permission_atom(:custom) == :custom
    end

    test "a provider name is not a permission" do
      assert Atoms.safe_to_permission_atom("github") == "github"
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

    test "a permission name is not a provider" do
      assert Atoms.safe_to_provider_atom("execute") == "execute"
    end
  end

  describe "security: atom table exhaustion prevention" do
    test "does not create atoms for random strings" do
      # Generate random strings that should not become atoms
      random_strings =
        for _ <- 1..100 do
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
