# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.SignatureVerifierTest do
  use ExUnit.Case, async: true

  alias Opus.SignatureVerifier

  describe "verify/3 with local/filesystem components" do
    test "allows filesystem source without any verification" do
      component = %{source: "filesystem", signature_verified: false}
      assert :ok = SignatureVerifier.verify(component, nil, nil)
    end

    test "allows published source without any verification" do
      component = %{source: "published", signature_verified: false}
      assert :ok = SignatureVerifier.verify(component, nil, nil)
    end

    test "allows nil source (legacy local components)" do
      component = %{source: nil, signature_verified: false}
      assert :ok = SignatureVerifier.verify(component, nil, nil)
    end

    test "allows filesystem source even with identity/issuer requested" do
      component = %{source: "filesystem", signature_verified: false}

      assert :ok =
               SignatureVerifier.verify(component, "dev@cyfr.run", "https://accounts.google.com")
    end
  end

  describe "verify/3 with verified OCI components" do
    test "allows verified OCI component without identity requirements" do
      component = %{
        source: "oci",
        signature_verified: true,
        signer_identity: "dev@cyfr.run",
        signer_issuer: "https://accounts.google.com"
      }

      assert :ok = SignatureVerifier.verify(component, nil, nil)
    end

    test "allows verified OCI component with matching identity" do
      component = %{
        source: "oci",
        signature_verified: true,
        signer_identity: "dev@cyfr.run",
        signer_issuer: "https://accounts.google.com"
      }

      assert :ok = SignatureVerifier.verify(component, "dev@cyfr.run", nil)
    end

    test "allows verified OCI component with matching issuer" do
      component = %{
        source: "oci",
        signature_verified: true,
        signer_identity: "dev@cyfr.run",
        signer_issuer: "https://accounts.google.com"
      }

      assert :ok = SignatureVerifier.verify(component, nil, "https://accounts.google.com")
    end

    test "allows verified OCI component with matching identity and issuer" do
      component = %{
        source: "oci",
        signature_verified: true,
        signer_identity: "dev@cyfr.run",
        signer_issuer: "https://accounts.google.com"
      }

      assert :ok =
               SignatureVerifier.verify(component, "dev@cyfr.run", "https://accounts.google.com")
    end

    test "rejects verified OCI component with mismatched identity" do
      component = %{
        source: "oci",
        signature_verified: true,
        signer_identity: "dev@cyfr.run",
        signer_issuer: "https://accounts.google.com"
      }

      {:error, msg} = SignatureVerifier.verify(component, "other@example.com", nil)
      assert msg =~ "identity mismatch"
    end

    test "rejects verified OCI component with mismatched issuer" do
      component = %{
        source: "oci",
        signature_verified: true,
        signer_identity: "dev@cyfr.run",
        signer_issuer: "https://accounts.google.com"
      }

      {:error, msg} = SignatureVerifier.verify(component, nil, "https://github.com/login/oauth")
      assert msg =~ "issuer mismatch"
    end

    test "rejects when identity requested but stored identity is nil" do
      component = %{
        source: "oci",
        signature_verified: true,
        signer_identity: nil,
        signer_issuer: nil
      }

      {:error, msg} = SignatureVerifier.verify(component, "dev@cyfr.run", nil)
      assert msg =~ "identity mismatch"
    end
  end

  describe "verify/3 with unverified OCI components" do
    test "rejects unverified OCI component" do
      component = %{source: "oci", signature_verified: false}
      {:error, msg} = SignatureVerifier.verify(component, "dev@cyfr.run", nil)
      assert msg =~ "without signature verification"
    end

    test "rejects OCI component with nil signature_verified" do
      component = %{source: "oci", signature_verified: nil}
      {:error, msg} = SignatureVerifier.verify(component, "dev@cyfr.run", nil)
      assert msg =~ "without signature verification"
    end
  end

  describe "verify/3 with string keys (from JSON/MCP)" do
    test "handles string-keyed component maps" do
      component = %{
        "source" => "oci",
        "signature_verified" => true,
        "signer_identity" => "dev@cyfr.run",
        "signer_issuer" => "https://accounts.google.com"
      }

      assert :ok =
               SignatureVerifier.verify(component, "dev@cyfr.run", "https://accounts.google.com")
    end

    test "rejects string-keyed unverified OCI component" do
      component = %{"source" => "oci", "signature_verified" => false}
      {:error, msg} = SignatureVerifier.verify(component, "dev@cyfr.run", nil)
      assert msg =~ "without signature verification"
    end
  end

  describe "verify/3 with non-map input" do
    test "returns error for non-map component" do
      {:error, msg} = SignatureVerifier.verify("not a map", nil, nil)
      assert msg =~ "Invalid component data"
    end
  end
end
