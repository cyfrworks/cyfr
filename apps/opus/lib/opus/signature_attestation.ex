# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.SignatureAttestation do
  @moduledoc """
  Reads the signature attestation recorded at pull time.

  No cryptography happens here: `Compendium.Cosign` verified (or failed to
  verify) the OCI signature when the component was pulled and the result was
  recorded on the row (`signature_verified`, `signer_identity`,
  `signer_issuer`). This module checks that recorded attestation at
  execution time — the name says what it reads, not what it proves.

  ## Trust Model

  - **Local/filesystem components**: Trusted by ownership — always pass.
  - **OCI components with verification**: Check that `signature_verified` is true.
    If caller provides `identity`/`issuer`, match against stored signer metadata.
  - **OCI components without verification**: Rejected when verify opts are provided.

  ## Usage

      # Check a component's recorded attestation
      :ok = SignatureAttestation.verify(component_map, nil, nil)

      # Verify with identity/issuer requirements
      :ok = SignatureAttestation.verify(component_map, "dev@cyfr.run", "https://accounts.google.com")
  """

  @doc """
  Verify a component's signature against stored metadata.

  ## Parameters

  - `component` - Component map with `source`, `signature_verified`, `signer_identity`, `signer_issuer`
  - `identity` - Expected signer identity (email or URI), or nil for any
  - `issuer` - Expected OIDC issuer URL, or nil for any

  ## Returns

  - `:ok` - Verification passed
  - `{:error, reason}` - Verification failed
  """
  @spec verify(map(), String.t() | nil, String.t() | nil) :: :ok | {:error, String.t()}
  def verify(component, identity, issuer) when is_map(component) do
    source = component["source"] || component[:source]
    verified = component["signature_verified"] || component[:signature_verified]
    stored_identity = component["signer_identity"] || component[:signer_identity]
    stored_issuer = component["signer_issuer"] || component[:signer_issuer]

    cond do
      # Local/filesystem components are trusted by ownership. `nil` is NOT
      # in this list: a missing source is an unclassified value, and the
      # closed-vocabulary arm below refuses it (the column is NOT NULL with
      # a default, so a nil here is a malformed caller, not a real row).
      source in [Compendium.Source.filesystem(), Compendium.Source.published()] ->
        :ok

      # OCI component with verification — check identity/issuer match if requested
      source == Compendium.Source.oci() and verified == true ->
        check_identity_match(identity, issuer, stored_identity, stored_issuer)

      # OCI component without verification — reject
      source == Compendium.Source.oci() ->
        {:error,
         "Component pulled from OCI registry without signature verification. Re-pull to verify."}

      # Unknown source — a verifier fails CLOSED. The source vocabulary is
      # closed (oci/filesystem/published); a new value must be classified
      # here before its components may execute.
      true ->
        {:error, "Unknown component source #{inspect(source)} — signature policy undefined"}
    end
  end

  def verify(_component, _identity, _issuer) do
    {:error, "Invalid component data for signature verification"}
  end

  defp check_identity_match(nil, nil, _stored_identity, _stored_issuer), do: :ok

  defp check_identity_match(identity, nil, stored_identity, _stored_issuer) do
    if identity_matches?(identity, stored_identity) do
      :ok
    else
      {:error,
       "Signer identity mismatch: expected #{identity}, got #{stored_identity || "unknown"}"}
    end
  end

  defp check_identity_match(nil, issuer, _stored_identity, stored_issuer) do
    if issuer_matches?(issuer, stored_issuer) do
      :ok
    else
      {:error, "Signer issuer mismatch: expected #{issuer}, got #{stored_issuer || "unknown"}"}
    end
  end

  defp check_identity_match(identity, issuer, stored_identity, stored_issuer) do
    with :ok <- check_identity_match(identity, nil, stored_identity, stored_issuer),
         :ok <- check_identity_match(nil, issuer, stored_identity, stored_issuer) do
      :ok
    end
  end

  defp identity_matches?(_expected, nil), do: false
  defp identity_matches?(expected, stored), do: expected == stored

  defp issuer_matches?(_expected, nil), do: false
  defp issuer_matches?(expected, stored), do: expected == stored
end
