# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.AtomsTest do
  use ExUnit.Case, async: true

  alias Sanctum.Atoms

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

  describe "security: atom table exhaustion prevention" do
    test "does not create atoms for random strings" do
      # Generate random strings that should not become atoms
      random_strings =
        for _ <- 1..100 do
          :crypto.strong_rand_bytes(16) |> Base.encode16()
        end

      results = Enum.map(random_strings, &Atoms.safe_to_permission_atom/1)

      # All results should be the original strings, not atoms
      for {result, original} <- Enum.zip(results, random_strings) do
        assert is_binary(result), "Expected string, got: #{inspect(result)}"
        assert result == original
      end
    end
  end
end
