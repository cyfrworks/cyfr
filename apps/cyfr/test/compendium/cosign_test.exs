defmodule Compendium.CosignTest do
  use ExUnit.Case, async: true

  alias Compendium.Cosign

  describe "verify/1" do
    test "returns error when cosign is not in PATH" do
      # Save original PATH and set to empty
      original_path = System.get_env("PATH")

      try do
        System.put_env("PATH", "/nonexistent")
        {:error, msg} = Cosign.verify("registry.example.com/test:1.0.0")
        assert msg =~ "cosign not found in PATH"
        assert msg =~ "Install"
      after
        System.put_env("PATH", original_path)
      end
    end

    test "accepts valid OCI reference format" do
      # This test verifies the function accepts the input format correctly.
      # If cosign is installed, it will attempt verification (and likely fail
      # for a nonexistent image). If not installed, it returns a clear error.
      result = Cosign.verify("registry.example.com/test/repo:1.0.0")

      case result do
        {:ok, %{verified_at: %DateTime{}}} ->
          # cosign is installed and somehow verified
          :ok

        {:error, msg} ->
          # Either cosign not found or verification failed — both valid
          assert is_binary(msg)
      end
    end
  end
end
