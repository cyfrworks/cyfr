# SPDX-License-Identifier: Apache-2.0
# Copyright 2024 CYFR Contributors

defmodule Sanctum.Edition do
  @moduledoc """
  Base edition info for community Sanctum.

  SanctumArx extends this with license validation and enterprise feature gating.
  For the Sanctum, all base features are always available.

  ## Usage

      if Sanctum.Edition.community?() do
        # Sanctum - full local functionality
      end

      if Sanctum.Edition.feature_available?(:api_keys) do
        # Feature is available (always true for community features)
      end

  """

  @community_features [
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

  @doc """
  Always returns true for base Sanctum.
  """
  @spec community?() :: boolean()
  def community?, do: true

  @doc """
  Always returns false for base Sanctum.

  Use SanctumArx for enterprise features.
  """
  @spec arx?() :: boolean()
  def arx?, do: false

  @doc """
  Check if a feature is available.

  In Sanctum, all community features are available.
  Sanctum Arx features always return false.
  """
  @spec feature_available?(atom()) :: boolean()
  def feature_available?(feature) when is_atom(feature) do
    feature in @community_features
  end

  @doc """
  Get list of available features in Sanctum.
  """
  @spec available_features() :: [atom()]
  def available_features, do: @community_features

  @doc """
  Get list of community features.
  """
  @spec community_features() :: [atom()]
  def community_features, do: @community_features

  @doc """
  Get edition info for display/API responses.
  """
  @spec info() :: map()
  def info do
    %{
      edition: :community,
      features: @community_features,
      license_valid: true,
      zombie_mode: false
    }
  end
end
