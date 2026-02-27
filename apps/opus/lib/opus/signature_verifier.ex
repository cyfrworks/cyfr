defmodule Opus.SignatureVerifier do
  @moduledoc """
  Signature verification for WASM components using Sigstore.

  This module provides signature verification for components before execution.
  It validates that components are signed by trusted identities.

  ## Deferred Verification Model

  Opus implements a **deferred verification model** where signature verification
  for OCI artifacts is handled by the **Compendium** layer, not Opus directly.

  ### Why Deferred?

  1. **Separation of Concerns**: Compendium handles OCI registry interactions
     (pull, push, verify). Opus handles execution.

  2. **Verification at Pull Time**: When Compendium pulls an OCI artifact, it
     verifies the signature and records the verification result. Opus trusts
     this verification.

  3. **Local Trust**: Components registered via `cyfr register` from the local
     filesystem are trusted by virtue of local ownership. Remote components
     pulled via `cyfr pull` are verified at pull time by Compendium.

  ## Trust Model (PRD §7.2)

  All published components require signatures. The trust decision flow:

  1. Pull OCI artifact from registry (Compendium)
  2. Verify Sigstore signature with cosign (Compendium)
  3. Check signer identity against trusted_signers in Host Policy (Compendium)
  4. Store verified artifact in local registry
  5. Execute from verified local source (Opus)

  ## Usage

      # Verify a component reference
      :ok = SignatureVerifier.verify("catalyst:local.claude:0.2.0", nil, nil)

      # Check if enforcement is enabled
      SignatureVerifier.enforce_signatures?()

  ## Implementation Status

  **Current**: Stub implementation that returns `:ok` for all verifications.
  This is intentional — verification is handled at pull/register time by
  Compendium, not at execution time.

  **Configuration**:

  Set `config :opus, :enforce_signatures` to control behavior:
  - `false` (default) - Stub verification, logs warnings
  - `true` - Requires real verification (will reject refs until implemented)
  """

  require Logger

  @doc false
  def enforce_signatures? do
    Application.get_env(:opus, :enforce_signatures, false)
  end

  @doc """
  Verify a component's signature against a specific identity and issuer.

  ## Parameters

  - `reference` - Component reference string (e.g., "catalyst:local.claude:0.2.0")
  - `identity` - Expected signer identity (email or URI)
  - `issuer` - Expected OIDC issuer URL

  ## Returns

  - `:ok` - Signature verified successfully
  - `{:error, reason}` - Verification failed

  ## Examples

      iex> SignatureVerifier.verify("catalyst:local.claude:0.2.0", nil, nil)
      :ok

  """
  @spec verify(String.t(), String.t() | nil, String.t() | nil) :: :ok | {:error, String.t()}
  def verify(reference, identity, issuer) when is_binary(reference) do
    if enforce_signatures?() do
      {:error,
       "Signature verification required but not yet implemented for #{reference}. " <>
         "Set `config :opus, enforce_signatures: false` to allow unverified execution."}
    else
      Logger.warning(
        "SignatureVerifier: STUB - #{reference} executed WITHOUT signature verification. " <>
          "identity=#{identity || "any"}, issuer=#{issuer || "any"}. " <>
          "Set `config :opus, enforce_signatures: true` to require verification."
      )

      :ok
    end
  end

  # Fallback for non-string references (shouldn't happen after simplification)
  def verify(reference, _identity, _issuer) do
    {:error, "Unknown reference format for signature verification: #{inspect(reference)}"}
  end

  @doc """
  Verify a component against the trusted signers from Host Policy.

  ## Parameters

  - `reference` - Component reference string
  - `component_type` - :catalyst, :reagent, or :formula
  - `ctx` - Sanctum context with user's Host Policy

  ## Returns

  - `:ok` - Component is trusted
  - `{:error, reason}` - Component is not trusted
  """
  @spec verify_trusted(String.t(), atom(), term()) :: :ok | {:error, String.t()}
  def verify_trusted(reference, component_type, _ctx) when is_binary(reference) do
    if enforce_signatures?() do
      {:error,
       "Signature verification required for #{reference} " <>
         "(component_type=#{component_type}) but not yet implemented. " <>
         "Set `config :opus, enforce_signatures: false` to allow unverified execution."}
    else
      Logger.warning(
        "SignatureVerifier: STUB - trusted verification for #{reference}, " <>
          "type=#{component_type}. Verification NOT actually performed. " <>
          "Set `config :opus, enforce_signatures: true` to require verification."
      )

      :ok
    end
  end
end
