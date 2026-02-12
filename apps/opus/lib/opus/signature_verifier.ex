defmodule Opus.SignatureVerifier do
  @moduledoc """
  Signature verification for WASM components using Sigstore.

  This module provides signature verification for OCI artifacts using Sigstore's
  cosign. It validates that components are signed by trusted identities before
  execution.

  ## Deferred Verification Model

  Opus implements a **deferred verification model** where signature verification
  for OCI artifacts is handled by the **Compendium** layer, not Opus directly.

  ### Why Deferred?

  1. **Separation of Concerns**: Compendium handles OCI registry interactions
     (pull, push, verify). Opus handles execution.

  2. **Verification at Pull Time**: When Compendium pulls an OCI artifact, it
     verifies the signature and records the verification result. Opus trusts
     this verification.

  3. **Local Trust**: Opus directly trusts certain reference types without
     signature verification:

  | Reference Type | Trust Basis | Verification |
  |---------------|-------------|--------------|
  | Local file | Local filesystem trust | None needed |
  | Registry | Local registry (Compendium) | None for local publisher |
  | Arca | User-owned storage | None needed |
  | OCI | Sigstore signature | Via Compendium |

  ## Trust Model (PRD §7.2)

  All published components require signatures. The trust decision flow:

  1. Pull OCI artifact from registry (Compendium)
  2. Verify Sigstore signature with cosign (Compendium)
  3. Check signer identity against trusted_signers in Host Policy (Compendium)
  4. Store verified artifact locally or in Arca
  5. Execute from verified local source (Opus)

  ## Component Types and Signature Requirements

  | Type | Signature Requirement |
  |------|----------------------|
  | Catalyst | Must match `trusted_signers.catalysts` (high privilege) |
  | Reagent | Any valid signature (sandboxed, lower risk) |
  | Formula | Any valid signature (composition only) |
  | Local | No signature required (local filesystem trust) |

  ## Usage

      # Verify against specific signer (for OCI refs pulled directly)
      :ok = SignatureVerifier.verify(
        %{"oci" => "registry.cyfr.run/tool:1.0"},
        "alice@example.com",
        "https://github.com/login/oauth"
      )

      # Verify with default trust rules
      :ok = SignatureVerifier.verify_trusted(%{"oci" => ref}, :catalyst, ctx)

      # Check if verification is needed
      SignatureVerifier.requires_verification?(%{"oci" => ref})  # true
      SignatureVerifier.requires_verification?(%{"local" => path}) # false

  ## Implementation Status

  **Current**: Stub implementation that returns `:ok` for all verifications.
  This is intentional because:

  1. Local files and Arca references don't need signature verification
  2. OCI verification is expected to be handled by Compendium before Opus sees
     the artifact

  **Configuration**:

  Set `config :opus, :enforce_signatures` to control behavior:
  - `false` (default) - Stub verification, logs warnings for OCI/registry refs
  - `true` - Requires real verification (will reject OCI refs until implemented)

  **Future Integration with Compendium**:
  - Compendium will use cosign CLI for OCI verification
  - Rekor transparency log validation
  - Certificate chain verification
  - Verification results cached with pulled artifacts
  """

  require Logger

  @doc false
  def enforce_signatures? do
    Application.get_env(:opus, :enforce_signatures, false)
  end

  @doc """
  Verify a component's signature against a specific identity and issuer.

  ## Parameters

  - `reference` - Component reference map (%{"oci" => ref} | %{"local" => path} | ...)
  - `identity` - Expected signer identity (email or URI)
  - `issuer` - Expected OIDC issuer URL

  ## Returns

  - `:ok` - Signature verified successfully
  - `{:error, reason}` - Verification failed

  ## Examples

      iex> SignatureVerifier.verify(%{"oci" => "registry.cyfr.run/tool:1.0"}, "security@cyfr.run", "https://github.com/login/oauth")
      :ok

      iex> SignatureVerifier.verify(%{"local" => "/path/to/file.wasm"}, nil, nil)
      :ok  # Local files don't require signature verification

  """
  @spec verify(map(), String.t() | nil, String.t() | nil) :: :ok | {:error, String.t()}
  def verify(reference, identity, issuer)

  # Local files don't require signature verification (trusted local environment)
  def verify(%{"local" => _path}, _identity, _issuer) do
    :ok
  end

  # Arca artifacts are user-owned, no signature required
  def verify(%{"arca" => _path}, _identity, _issuer) do
    :ok
  end

  # OCI references require signature verification
  # NOTE: In the production model, OCI artifacts should be pulled and verified
  # by Compendium before being passed to Opus. This function exists for:
  # 1. Direct OCI references that bypass Compendium (testing/development)
  # 2. Future integration where Opus verifies directly
  def verify(%{"oci" => oci_ref}, identity, issuer) do
    if enforce_signatures?() do
      {:error,
       "Signature verification required but not yet implemented for OCI ref: #{oci_ref}. " <>
         "Set `config :opus, enforce_signatures: false` to allow unverified execution, " <>
         "or use Compendium to pull and verify first."}
    else
      Logger.warning(
        "SignatureVerifier: STUB - OCI ref #{oci_ref} executed WITHOUT signature verification. " <>
          "identity=#{identity || "any"}, issuer=#{issuer || "any"}. " <>
          "Set `config :opus, enforce_signatures: true` to require verification."
      )

      :ok
    end
  end

  # Registry references also require signature verification
  def verify(%{"registry" => registry_ref}, _identity, _issuer) do
    if enforce_signatures?() do
      {:error,
       "Signature verification required but not yet implemented for registry ref: #{registry_ref}. " <>
         "Set `config :opus, enforce_signatures: false` to allow unverified execution."}
    else
      Logger.warning(
        "SignatureVerifier: STUB - registry ref #{registry_ref} executed WITHOUT signature verification. " <>
          "Set `config :opus, enforce_signatures: true` to require verification."
      )

      :ok
    end
  end

  # Unknown reference format
  def verify(reference, _identity, _issuer) do
    {:error, "Unknown reference format for signature verification: #{inspect(reference)}"}
  end

  @doc """
  Verify a component against the trusted signers from Host Policy.

  This is the higher-level API that checks the component type and applies
  the appropriate trust rules from the user's Host Policy.

  ## Parameters

  - `reference` - Component reference map
  - `component_type` - :catalyst, :reagent, or :formula
  - `ctx` - Sanctum context with user's Host Policy

  ## Returns

  - `:ok` - Component is trusted
  - `{:error, reason}` - Component is not trusted

  ## Future Implementation

  This will integrate with Sanctum to:
  1. Load user's Host Policy trusted_signers configuration
  2. Extract signer identity from component's Sigstore signature
  3. Match against allowed identities for the component type
  """
  @spec verify_trusted(map(), atom(), term()) :: :ok | {:error, String.t()}
  def verify_trusted(reference, component_type, _ctx) do
    # Local/Arca references are trusted via ownership/local trust
    # OCI/Registry references require real verification when enforce_signatures is true
    requires = requires_verification?(reference)

    if requires and enforce_signatures?() do
      {:error,
       "Signature verification required for #{inspect(reference)} " <>
         "(component_type=#{component_type}) but not yet implemented. " <>
         "Set `config :opus, enforce_signatures: false` to allow unverified execution."}
    else
      if requires do
        Logger.warning(
          "SignatureVerifier: STUB - trusted verification for #{inspect(reference)}, " <>
            "type=#{component_type}. Verification NOT actually performed. " <>
            "Set `config :opus, enforce_signatures: true` to require verification."
        )
      end

      :ok
    end
  end

  @doc """
  Check if a component reference requires signature verification.

  ## Examples

      iex> SignatureVerifier.requires_verification?(%{"oci" => "..."})
      true

      iex> SignatureVerifier.requires_verification?(%{"local" => "..."})
      false

  """
  @spec requires_verification?(map()) :: boolean()
  def requires_verification?(%{"oci" => _}), do: true
  def requires_verification?(%{"registry" => _}), do: true
  def requires_verification?(%{"local" => _}), do: false
  def requires_verification?(%{"arca" => _}), do: false
  def requires_verification?(_), do: false
end
