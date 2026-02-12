# SPDX-License-Identifier: FSL-1.1-MIT
# Copyright 2024 CYFR Inc. All Rights Reserved.

defmodule SanctumArx.Edition do
  @moduledoc """
  Edition feature gates for Sanctum Arx.

  This module provides compile-time and runtime feature gating based on the
  configured edition (base Sanctum or Sanctum Arx).

  ## Editions

  | Component | License | Target |
  |-----------|---------|--------|
  | **Sanctum** | Apache 2.0 | Single developer, SQLite, local dev |
  | **Sanctum Arx** | FSL 1.1 | Enterprise IT, Postgres, SAML, audit |

  ## Feature Matrix

  | Feature | Sanctum | Sanctum Arx |
  |---------|---------|-------------|
  | Auth | GitHub/Google OIDC | + SAML 2.0, Custom OIDC, SCIM |
  | Storage | SQLite (local) | Postgres/Redis HA |
  | Secrets backend | Local encrypted | + HashiCorp Vault, AWS KMS |
  | Policy | Local YAML | + GitOps sync, RBAC |
  | Audit | Last 10 executions | Infinite / S3-backed |
  | Logs | Console | + SIEM forwarding |
  | Scale | Single instance | Multi-node cluster |

  ## Usage

      # Check edition at runtime
      if SanctumArx.Edition.arx?() do
        # Arx-only code path
      end

      # Check specific feature availability
      if SanctumArx.Edition.feature_available?(:saml) do
        # SAML is available
      end

      # Guard against unauthorized feature usage
      SanctumArx.Edition.require_feature!(:vault)  # raises if not available

  ## Philosophy

  > "Developers get full functionality locally. Enterprises pay for governance."

  The code is the same. The **packaging** is different:
  - Base release: Ships with `edition: :community`, no license check
  - Arx release: Ships with `edition: :arx`, validates `license.sig`

  """

  alias SanctumArx.License

  # ============================================================================
  # Feature Definitions
  # ============================================================================

  @community_features [
    # Auth
    :github_oidc,
    :google_oidc,

    # Storage
    :sqlite_storage,
    :local_secrets,

    # Policy
    :yaml_policy,
    :local_policy,

    # Audit
    :basic_audit,

    # Core functionality
    :execute,
    :component_management,
    :api_keys,
    :sessions
  ]

  @arx_features [
    # Auth
    :saml,
    :scim,
    :custom_oidc,
    :okta,
    :azure_ad,

    # Storage
    :postgres_storage,
    :redis_storage,
    :ha_storage,

    # Secrets
    :vault_secrets,
    :aws_kms,
    :azure_keyvault,
    :gcp_kms,

    # Policy
    :gitops_policy,
    :advanced_rbac,
    :policy_versioning,

    # Audit
    :unlimited_audit,
    :s3_audit_export,
    :siem_forwarding,
    :compliance_reports,

    # Scale
    :multi_node,
    :clustering,
    :load_balancing,

    # Arx support
    :priority_support,
    :sla_guarantees
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Check if running in base Sanctum edition.

  ## Examples

      iex> SanctumArx.Edition.community?()
      true

  """
  @spec community?() :: boolean()
  def community? do
    License.edition() == :community
  end

  @doc """
  Check if running in Sanctum Arx edition.

  Note: This checks the configured edition, not license validity.
  Use `SanctumArx.License.valid?/0` to check if the license is still valid.

  ## Examples

      iex> SanctumArx.Edition.arx?()
      false

  """
  @spec arx?() :: boolean()
  def arx? do
    License.edition() == :arx
  end

  @doc """
  Check if a specific feature is available in the current edition.

  Community features are always available.
  Arx features require Sanctum Arx edition with valid license.

  ## Examples

      iex> SanctumArx.Edition.feature_available?(:github_oidc)
      true

      iex> SanctumArx.Edition.feature_available?(:saml)
      false  # Requires Arx

  """
  @spec feature_available?(atom()) :: boolean()
  def feature_available?(feature) when is_atom(feature) do
    cond do
      feature in @community_features ->
        true

      feature in @arx_features ->
        arx?() and License.valid?() and License.feature_licensed?(feature)

      true ->
        # Unknown feature - allow in Arx, deny in community
        arx?() and License.valid?()
    end
  end

  @doc """
  Require a feature to be available, raising if not.

  Use this to guard enterprise-only code paths.

  ## Examples

      iex> SanctumArx.Edition.require_feature!(:github_oidc)
      :ok

      iex> SanctumArx.Edition.require_feature!(:saml)
      ** (SanctumArx.Edition.FeatureNotAvailable) Feature :saml requires Sanctum Arx edition

  """
  @spec require_feature!(atom()) :: :ok
  def require_feature!(feature) when is_atom(feature) do
    if feature_available?(feature) do
      :ok
    else
      raise __MODULE__.FeatureNotAvailable, feature: feature
    end
  end

  @doc """
  Get list of available features for current edition.

  ## Examples

      iex> SanctumArx.Edition.available_features()
      [:github_oidc, :google_oidc, ...]

  """
  @spec available_features() :: [atom()]
  def available_features do
    if arx?() and License.valid?() do
      @community_features ++ licensed_arx_features()
    else
      @community_features
    end
  end

  @doc """
  Get list of all community features.

  ## Examples

      iex> SanctumArx.Edition.community_features()
      [:github_oidc, :google_oidc, ...]

  """
  @spec community_features() :: [atom()]
  def community_features, do: @community_features

  @doc """
  Get list of all Arx features.

  ## Examples

      iex> SanctumArx.Edition.arx_features()
      [:saml, :scim, ...]

  """
  @spec arx_features() :: [atom()]
  def arx_features, do: @arx_features

  @doc """
  Get edition info for display/API responses.

  ## Examples

      iex> SanctumArx.Edition.info()
      %{
        edition: :community,
        features: [:github_oidc, ...],
        license_valid: true
      }

  """
  @spec info() :: map()
  def info do
    %{
      edition: License.edition(),
      features: available_features(),
      license_valid: License.valid?(),
      zombie_mode: License.zombie_mode?()
    }
  end

  # ============================================================================
  # Feature Macros for Compile-Time Gating
  # ============================================================================

  # Store compile-time edition for use in macros
  @compile_edition Application.compile_env(:sanctum_arx, :edition, :community)

  @doc """
  Macro for compile-time feature gating.

  Use this to conditionally compile code based on edition.

  ## Examples

      defmodule MyModule do
        import SanctumArx.Edition

        # This function only exists in Arx builds
        if_arx do
          def saml_login(params), do: # ...
        end
      end

  Note: Compile-time gating uses the edition configured at compile time.
  For runtime flexibility, use `feature_available?/1` instead.
  """
  defmacro if_arx(do: block) do
    quote do
      if unquote(@compile_edition) == :arx do
        unquote(block)
      end
    end
  end

  defmacro if_community(do: block) do
    quote do
      if unquote(@compile_edition) == :community do
        unquote(block)
      end
    end
  end

  @doc """
  Macro for conditional feature compilation.

  ## Examples

      defmodule SanctumArx.Secrets do
        import SanctumArx.Edition

        with_feature :vault_secrets do
          defp vault_backend, do: SanctumArx.Secrets.Vault
        end

        with_feature :aws_kms do
          defp kms_backend, do: SanctumArx.Secrets.KMS
        end
      end

  """
  defmacro with_feature(feature, do: block) do
    community_features = [
      :github_oidc,
      :google_oidc,
      :sqlite_storage,
      :local_secrets,
      :yaml_policy,
      :local_policy,
      :basic_audit,
      :execute,
      :component_management,
      :api_keys,
      :sessions
    ]

    # Check if feature is in community features or if we're building arx edition.
    # This is evaluated at macro expansion time (compile time).
    is_community_feature = feature in community_features
    is_arx_build = @compile_edition == :arx

    if is_community_feature or is_arx_build do
      block
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp licensed_arx_features do
    case License.current_license() do
      %{features: features} when is_list(features) ->
        if "*" in features do
          @arx_features
        else
          Enum.filter(@arx_features, fn f ->
            Atom.to_string(f) in features
          end)
        end

      _ ->
        []
    end
  end

  # ============================================================================
  # Exceptions
  # ============================================================================

  defmodule FeatureNotAvailable do
    @moduledoc """
    Raised when attempting to use an Arx feature without proper license.
    """
    defexception [:feature, :message]

    @impl true
    def exception(opts) do
      feature = Keyword.fetch!(opts, :feature)
      edition = SanctumArx.License.edition()

      message =
        case edition do
          :community ->
            "Feature #{inspect(feature)} requires Sanctum Arx. " <>
              "Contact sales@cyfr.dev to upgrade."

          :arx ->
            if SanctumArx.License.zombie_mode?() do
              "Feature #{inspect(feature)} unavailable - license expired. " <>
                "Please renew your license."
            else
              "Feature #{inspect(feature)} is not included in your license. " <>
                "Contact support@cyfr.dev to add this feature."
            end
        end

      %__MODULE__{feature: feature, message: message}
    end
  end
end
