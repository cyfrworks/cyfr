# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.CosignTest do
  use ExUnit.Case, async: false

  alias Compendium.Cosign

  setup do
    original = Application.get_env(:cyfr, :sigstore)

    on_exit(fn ->
      if original,
        do: Application.put_env(:cyfr, :sigstore, original),
        else: Application.delete_env(:cyfr, :sigstore)
    end)

    :ok
  end

  # Keyless verification against `.*` identity and `.*` issuer accepts a
  # signature from anyone who can obtain a Sigstore certificate — while the
  # component row it feeds records `signature_verified: true`. An operator
  # who wants keyless has to say whose signature counts.
  describe "keyless verification requires a named signer" do
    test "refuses when neither identity nor issuer is configured" do
      Application.put_env(:cyfr, :sigstore, verification: :keyless)

      assert {:error, msg} = Cosign.verify("registry.example.com/test:1.0.0")
      assert msg =~ "CYFR_COSIGN_IDENTITY"
      assert msg =~ "CYFR_COSIGN_ISSUER"
    end

    test "refuses when only one half is configured" do
      for partial <- [
            [verification: :keyless, identity: "someone@example.com"],
            [verification: :keyless, issuer: "https://accounts.google.com"],
            [verification: :keyless, identity: "", issuer: ""]
          ] do
        Application.put_env(:cyfr, :sigstore, partial)

        assert {:error, msg} = Cosign.verify("registry.example.com/test:1.0.0")
        assert msg =~ "keyless signature verification needs a signer"
      end
    end

    test "a fully named signer gets past the configuration gate" do
      Application.put_env(:cyfr, :sigstore,
        verification: :keyless,
        identity: "release@example.com",
        issuer: "https://accounts.google.com"
      )

      # Past the gate the call reaches cosign itself, which either is not
      # installed or cannot verify a nonexistent image — both are failures
      # from the tool, not the refusal above.
      case Cosign.verify("registry.example.com/test:1.0.0") do
        {:ok, %{verified_at: %DateTime{}}} -> :ok
        {:error, msg} -> refute msg =~ "needs a signer"
      end
    end
  end

  describe "verify/1" do
    test "returns error when cosign is not in PATH" do
      # A configured signer, so the missing tool is what this reaches: the
      # configuration gate runs first and would otherwise answer instead.
      Application.put_env(:cyfr, :sigstore,
        verification: :keyless,
        identity: "release@example.com",
        issuer: "https://accounts.google.com"
      )

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
      Application.put_env(:cyfr, :sigstore,
        verification: :keyless,
        identity: "release@example.com",
        issuer: "https://accounts.google.com"
      )

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
