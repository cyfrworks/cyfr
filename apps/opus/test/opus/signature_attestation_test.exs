# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.SignatureAttestationTest do
  use ExUnit.Case, async: true

  alias Opus.SignatureAttestation

  describe "attestation/1" do
    # `Opus.Executor` reads this instead of `verify/3` alone because only one
    # of the four answers is the operator's call. Before it existed the whole
    # check hung on the caller's `:verify` argument, whose one producer is a
    # client's own MCP tool call — so children, schedules and tincture
    # ingress executed unsigned OCI code without reading the row at all.
    test "filesystem and published are trusted by ownership" do
      assert :trusted = SignatureAttestation.attestation(%{source: "filesystem"})
      assert :trusted = SignatureAttestation.attestation(%{source: "published"})
    end

    test "a verified OCI pull is signed" do
      assert :signed =
               SignatureAttestation.attestation(%{source: "oci", signature_verified: true})
    end

    test "an OCI pull that did not verify is unsigned, whatever the row says elsewhere" do
      assert :unsigned =
               SignatureAttestation.attestation(%{source: "oci", signature_verified: false})

      assert :unsigned = SignatureAttestation.attestation(%{source: "oci"})
    end

    test "anything else is unclassified, and the caller must fail closed on it" do
      assert {:unknown_source, nil} = SignatureAttestation.attestation(%{source: nil})
      assert {:unknown_source, "hg"} = SignatureAttestation.attestation(%{source: "hg"})
    end

    test "reads string and atom keys alike — rows arrive both ways" do
      assert :signed =
               SignatureAttestation.attestation(%{
                 "source" => "oci",
                 "signature_verified" => true
               })
    end
  end

  describe "verify/3 with local/filesystem components" do
    test "allows filesystem source without any verification" do
      component = %{source: "filesystem", signature_verified: false}
      assert :ok = SignatureAttestation.verify(component, nil, nil)
    end

    test "allows published source without any verification" do
      component = %{source: "published", signature_verified: false}
      assert :ok = SignatureAttestation.verify(component, nil, nil)
    end

    test "refuses a nil source — an unclassified value, not a legacy pass" do
      # The components.source column is NOT NULL with a default, so a nil
      # here is a malformed caller, never a real row; the closed source
      # vocabulary fails closed on it like any other unknown value.
      component = %{source: nil, signature_verified: false}
      assert {:error, message} = SignatureAttestation.verify(component, nil, nil)
      assert message =~ "signature policy undefined"
    end

    test "allows filesystem source even with identity/issuer requested" do
      component = %{source: "filesystem", signature_verified: false}

      assert :ok =
               SignatureAttestation.verify(
                 component,
                 "dev@cyfr.run",
                 "https://accounts.google.com"
               )
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

      assert :ok = SignatureAttestation.verify(component, nil, nil)
    end

    test "allows verified OCI component with matching identity" do
      component = %{
        source: "oci",
        signature_verified: true,
        signer_identity: "dev@cyfr.run",
        signer_issuer: "https://accounts.google.com"
      }

      assert :ok = SignatureAttestation.verify(component, "dev@cyfr.run", nil)
    end

    test "allows verified OCI component with matching issuer" do
      component = %{
        source: "oci",
        signature_verified: true,
        signer_identity: "dev@cyfr.run",
        signer_issuer: "https://accounts.google.com"
      }

      assert :ok = SignatureAttestation.verify(component, nil, "https://accounts.google.com")
    end

    test "allows verified OCI component with matching identity and issuer" do
      component = %{
        source: "oci",
        signature_verified: true,
        signer_identity: "dev@cyfr.run",
        signer_issuer: "https://accounts.google.com"
      }

      assert :ok =
               SignatureAttestation.verify(
                 component,
                 "dev@cyfr.run",
                 "https://accounts.google.com"
               )
    end

    test "rejects verified OCI component with mismatched identity" do
      component = %{
        source: "oci",
        signature_verified: true,
        signer_identity: "dev@cyfr.run",
        signer_issuer: "https://accounts.google.com"
      }

      {:error, msg} = SignatureAttestation.verify(component, "other@example.com", nil)
      assert msg =~ "identity mismatch"
    end

    test "rejects verified OCI component with mismatched issuer" do
      component = %{
        source: "oci",
        signature_verified: true,
        signer_identity: "dev@cyfr.run",
        signer_issuer: "https://accounts.google.com"
      }

      {:error, msg} =
        SignatureAttestation.verify(component, nil, "https://github.com/login/oauth")

      assert msg =~ "issuer mismatch"
    end

    test "rejects when identity requested but stored identity is nil" do
      component = %{
        source: "oci",
        signature_verified: true,
        signer_identity: nil,
        signer_issuer: nil
      }

      {:error, msg} = SignatureAttestation.verify(component, "dev@cyfr.run", nil)
      assert msg =~ "identity mismatch"
    end
  end

  describe "verify/3 with unverified OCI components" do
    test "rejects unverified OCI component" do
      component = %{source: "oci", signature_verified: false}
      {:error, msg} = SignatureAttestation.verify(component, "dev@cyfr.run", nil)
      assert msg =~ "without signature verification"
    end

    test "rejects OCI component with nil signature_verified" do
      component = %{source: "oci", signature_verified: nil}
      {:error, msg} = SignatureAttestation.verify(component, "dev@cyfr.run", nil)
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
               SignatureAttestation.verify(
                 component,
                 "dev@cyfr.run",
                 "https://accounts.google.com"
               )
    end

    test "rejects string-keyed unverified OCI component" do
      component = %{"source" => "oci", "signature_verified" => false}
      {:error, msg} = SignatureAttestation.verify(component, "dev@cyfr.run", nil)
      assert msg =~ "without signature verification"
    end
  end

  describe "verify/3 with non-map input" do
    test "returns error for non-map component" do
      {:error, msg} = SignatureAttestation.verify("not a map", nil, nil)
      assert msg =~ "Invalid component data"
    end
  end
end
