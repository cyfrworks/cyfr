defmodule Compendium.Application do
  @moduledoc false

  require Logger

  @doc false
  def validate_registry_config! do
    validate_registry_credentials!()
    validate_registry_url!()
    validate_api_url!()
  end

  defp validate_registry_credentials! do
    case Application.get_env(:cyfr, :registry) do
      nil ->
        Application.put_env(:cyfr, :registry_credentials_status, :missing)

        if Compendium.Edition.core_edition?() do
          Logger.debug(
            "[Compendium] No registry credentials configured. " <>
              "Public components will work. Run `cyfr login` for authenticated access."
          )
        else
          Logger.warning(
            "[Compendium] No registry credentials configured for Arx edition. " <>
              "Anonymous access will be used. Set CYFR_REGISTRY_URL with credentials " <>
              "for authenticated registry access."
          )
        end

      _config ->
        Application.put_env(:cyfr, :registry_credentials_status, :configured)
    end
  end

  defp validate_registry_url! do
    case Application.get_env(:cyfr, :registry) do
      config when is_list(config) ->
        url = Keyword.get(config, :url)

        if Compendium.Edition.core_edition?() and is_binary(url) and url != "registry.cyfr.run" do
          raise """
          Registry misconfiguration detected!

          CYFR_REGISTRY_URL is set to "#{url}" but the current edition is Core.
          Core edition only supports registry.cyfr.run — this is not configurable.

          To use custom registries, upgrade to Sanctum Arx (CYFR_EDITION=arx).
          To use the default registry, remove CYFR_REGISTRY_URL from your configuration.
          """
        end

      _ ->
        unless Compendium.Edition.core_edition?() do
          Logger.warning(
            "[Compendium] Arx edition active but no CYFR_REGISTRY_URL configured. " <>
              "Operations will default to registry.cyfr.run. " <>
              "For air-gapped deployments, set CYFR_REGISTRY_URL to your internal registry."
          )
        end
    end
  end

  defp validate_api_url! do
    api_url = Application.get_env(:cyfr, :cyfr_run_api_url)

    if Compendium.Edition.core_edition?() and is_binary(api_url) do
      raise """
      API URL misconfiguration detected!

      CYFR_RUN_API_URL is set to "#{api_url}" but the current edition is Core.
      Core edition uses https://cyfr.run exclusively — this is not configurable.

      To use a custom cyfr.run instance, upgrade to Sanctum Arx (CYFR_EDITION=arx).
      To use the default API, remove CYFR_RUN_API_URL from your configuration.
      """
    end
  end
end
