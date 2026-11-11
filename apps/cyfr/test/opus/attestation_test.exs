# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.AttestationTest do
  use ExUnit.Case, async: true

  alias Opus.Attestation

  describe "attestation/1" do
    # `Opus.Admission` reads this as well as `verify/3` because only one of
    # the four answers is the operator's call, and the caller's `:verify`
    # argument comes only from a client's own MCP tool call: children,
    # schedules and tincture ingress are judged by the row alone.
    test "filesystem and published are trusted by ownership" do
      assert :trusted = Attestation.attestation(%{"source" => "filesystem"})
      assert :trusted = Attestation.attestation(%{"source" => "published"})
    end

    test "a verified OCI pull is signed" do
      assert :signed =
               Attestation.attestation(%{"source" => "oci", "signature_verified" => true})
    end

    test "an OCI pull that did not verify is unsigned, whatever the row says elsewhere" do
      assert :unsigned =
               Attestation.attestation(%{"source" => "oci", "signature_verified" => false})

      assert :unsigned = Attestation.attestation(%{"source" => "oci"})
    end

    test "anything else is unclassified, and the caller must fail closed on it" do
      assert {:unknown_source, nil} = Attestation.attestation(%{"source" => nil})
      assert {:unknown_source, "hg"} = Attestation.attestation(%{"source" => "hg"})
    end
  end

  describe "verify/3 with local/filesystem components" do
    test "allows filesystem source without any verification" do
      component = %{"source" => "filesystem", "signature_verified" => false}
      assert :ok = Attestation.verify(component, nil, nil)
    end

    test "allows published source without any verification" do
      component = %{"source" => "published", "signature_verified" => false}
      assert :ok = Attestation.verify(component, nil, nil)
    end

    test "refuses a nil source as an unclassified value" do
      # The components.source column is NOT NULL with a default, so a nil
      # here is a malformed caller, never a real row; the closed source
      # vocabulary fails closed on it like any other unknown value.
      component = %{"source" => nil, "signature_verified" => false}
      assert {:error, message} = Attestation.verify(component, nil, nil)
      assert message =~ "signature policy undefined"
    end

    test "allows filesystem source even with identity/issuer requested" do
      component = %{"source" => "filesystem", "signature_verified" => false}

      assert :ok =
               Attestation.verify(
                 component,
                 "dev@cyfr.run",
                 "https://accounts.google.com"
               )
    end
  end

  describe "verify/3 with verified OCI components" do
    test "allows verified OCI component without identity requirements" do
      component = %{
        "source" => "oci",
        "signature_verified" => true,
        "signer_identity" => "dev@cyfr.run",
        "signer_issuer" => "https://accounts.google.com"
      }

      assert :ok = Attestation.verify(component, nil, nil)
    end

    test "allows verified OCI component with matching identity" do
      component = %{
        "source" => "oci",
        "signature_verified" => true,
        "signer_identity" => "dev@cyfr.run",
        "signer_issuer" => "https://accounts.google.com"
      }

      assert :ok = Attestation.verify(component, "dev@cyfr.run", nil)
    end

    test "allows verified OCI component with matching issuer" do
      component = %{
        "source" => "oci",
        "signature_verified" => true,
        "signer_identity" => "dev@cyfr.run",
        "signer_issuer" => "https://accounts.google.com"
      }

      assert :ok = Attestation.verify(component, nil, "https://accounts.google.com")
    end

    test "allows verified OCI component with matching identity and issuer" do
      component = %{
        "source" => "oci",
        "signature_verified" => true,
        "signer_identity" => "dev@cyfr.run",
        "signer_issuer" => "https://accounts.google.com"
      }

      assert :ok =
               Attestation.verify(
                 component,
                 "dev@cyfr.run",
                 "https://accounts.google.com"
               )
    end

    test "rejects verified OCI component with mismatched identity" do
      component = %{
        "source" => "oci",
        "signature_verified" => true,
        "signer_identity" => "dev@cyfr.run",
        "signer_issuer" => "https://accounts.google.com"
      }

      {:error, msg} = Attestation.verify(component, "other@example.com", nil)
      assert msg =~ "identity mismatch"
    end

    test "rejects verified OCI component with mismatched issuer" do
      component = %{
        "source" => "oci",
        "signature_verified" => true,
        "signer_identity" => "dev@cyfr.run",
        "signer_issuer" => "https://accounts.google.com"
      }

      {:error, msg} =
        Attestation.verify(component, nil, "https://github.com/login/oauth")

      assert msg =~ "issuer mismatch"
    end

    # A keyless verification records no signer (Compendium.Cosign): every
    # pin on such a row is refused, an empty record as much as a missing one.
    test "a row that records no signer refuses every pin and admits an unpinned run" do
      for stored <- [nil, ""] do
        component = %{
          "source" => "oci",
          "signature_verified" => true,
          "signer_identity" => stored,
          "signer_issuer" => stored
        }

        for {identity, issuer} <- [
              {"dev@cyfr.run", nil},
              {nil, "https://accounts.google.com"},
              {"dev@cyfr.run", "https://accounts.google.com"},
              {"", nil},
              {nil, ""}
            ] do
          {:error, msg} = Attestation.verify(component, identity, issuer)
          assert msg =~ "records no signer"
        end

        assert :ok = Attestation.verify(component, nil, nil)
      end
    end

    test "a keyed row's pin on its key still verifies, and another key's is refused" do
      key = "key:sha256:" <> String.duplicate("f", 64)

      component = %{
        "source" => "oci",
        "signature_verified" => true,
        "signer_identity" => key,
        "signer_issuer" => "key"
      }

      assert :ok = Attestation.verify(component, key, nil)
      assert :ok = Attestation.verify(component, key, "key")
      assert :ok = Attestation.verify(component, nil, "key")

      {:error, msg} =
        Attestation.verify(component, "key:sha256:" <> String.duplicate("e", 64), "key")

      assert msg =~ "identity mismatch"
    end
  end

  describe "verify/3 with unverified OCI components" do
    test "rejects unverified OCI component" do
      component = %{"source" => "oci", "signature_verified" => false}
      {:error, msg} = Attestation.verify(component, "dev@cyfr.run", nil)
      assert msg =~ "without signature verification"
    end

    test "rejects OCI component with nil signature_verified" do
      component = %{"source" => "oci", "signature_verified" => nil}
      {:error, msg} = Attestation.verify(component, "dev@cyfr.run", nil)
      assert msg =~ "without signature verification"
    end
  end

  describe "verify/3 with identity and issuer pinned together" do
    test "allows a verified OCI component matching both" do
      component = %{
        "source" => "oci",
        "signature_verified" => true,
        "signer_identity" => "dev@cyfr.run",
        "signer_issuer" => "https://accounts.google.com"
      }

      assert :ok =
               Attestation.verify(
                 component,
                 "dev@cyfr.run",
                 "https://accounts.google.com"
               )
    end

    test "rejects an unverified OCI component" do
      component = %{"source" => "oci", "signature_verified" => false}
      {:error, msg} = Attestation.verify(component, "dev@cyfr.run", nil)
      assert msg =~ "without signature verification"
    end
  end
end
