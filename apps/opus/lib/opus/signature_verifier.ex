defmodule Opus.SignatureVerifier do
  @moduledoc """
  Signature verification for WASM components at execution time.

  Verifies that OCI-sourced components have been signature-verified at pull time
  by checking stored metadata (set by Compendium.Cosign during `cyfr pull`).

  ## Trust Model

  - **Local/filesystem components**: Trusted by ownership — always pass.
  - **OCI components with verification**: Check that `signature_verified` is true.
    If caller provides `identity`/`issuer`, match against stored signer metadata.
  - **OCI components without verification**: Rejected when verify opts are provided.

  ## Usage

      # Verify a component's signature metadata
      :ok = SignatureVerifier.verify(component_map, nil, nil)

      # Verify with identity/issuer requirements
      :ok = SignatureVerifier.verify(component_map, "dev@cyfr.run", "https://accounts.google.com")
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
      # Local/filesystem components are trusted by ownership
      source in ["filesystem", "published", nil] ->
        :ok

      # OCI component with verification — check identity/issuer match if requested
      source == "oci" and verified == true ->
        check_identity_match(identity, issuer, stored_identity, stored_issuer)

      # OCI component without verification — reject
      source == "oci" ->
        {:error,
         "Component pulled from OCI registry without signature verification. Re-pull to verify."}

      # Unknown source — allow (future-proofing)
      true ->
        :ok
    end
  end

  # Fallback for non-map (shouldn't happen after executor changes)
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
