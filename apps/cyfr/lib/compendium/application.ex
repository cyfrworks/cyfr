defmodule Compendium.Application do
  @moduledoc false

  require Logger

  @doc false
  def validate_registry_config! do
    validate_registry_url!()
    validate_oci_registry_url!()
  end

  # REST API host for cyfr.run (search, discover, probe, namespaces, etc).
  # Core is hard-pinned to "cyfr.run"; Arx may override for self-hosted /
  # air-gapped deployments.
  defp validate_registry_url! do
    url = Application.get_env(:cyfr, :registry_url)

    if Sanctum.Edition.core?() and is_binary(url) and url != "cyfr.run" do
      raise """
      Registry URL misconfiguration detected!

      CYFR_REGISTRY_URL is set to "#{url}" but the current edition is Core.
      Core edition only supports cyfr.run — this is not configurable.

      To self-host the registry, upgrade to Sanctum Arx (CYFR_EDITION=arx).
      To use the default, remove CYFR_REGISTRY_URL from your configuration.
      """
    end

    unless Sanctum.Edition.core?() or is_binary(url) do
      Logger.warning(
        "[Compendium] Arx edition active but no CYFR_REGISTRY_URL configured. " <>
          "Operations will default to cyfr.run. For air-gapped deployments, " <>
          "set CYFR_REGISTRY_URL to your internal REST host."
      )
    end
  end

  # OCI Distribution host (e.g. "registry.cyfr.run") — where components are
  # pushed/pulled. Core pins to "registry.cyfr.run"; Arx may override.
  defp validate_oci_registry_url! do
    url = Application.get_env(:cyfr, :oci_registry_url)

    if Sanctum.Edition.core?() and is_binary(url) and url != "registry.cyfr.run" do
      raise """
      OCI Registry URL misconfiguration detected!

      CYFR_OCI_REGISTRY_URL is set to "#{url}" but the current edition is Core.
      Core edition only supports registry.cyfr.run — this is not configurable.

      To self-host the OCI gateway, upgrade to Sanctum Arx (CYFR_EDITION=arx).
      To use the default, remove CYFR_OCI_REGISTRY_URL from your configuration.
      """
    end
  end
end
