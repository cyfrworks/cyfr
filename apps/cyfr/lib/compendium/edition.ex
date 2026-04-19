defmodule Compendium.Edition do
  @moduledoc """
  Edition-aware registry enforcement for Compendium.

  Core edition (the default) restricts all OCI operations to `registry.cyfr.run`.
  Sanctum Arx edition allows any registry.
  """

  @default_cyfr_run_registry "registry.cyfr.run"
  @default_rest_host "cyfr.run"

  @doc """
  Returns the canonical CYFR OCI registry hostname.

  Sourced from `:cyfr, :oci_registry_url` (set by `config/runtime.exs` with
  default `"registry.cyfr.run"` on Core; Arx deployments can override via
  `CYFR_OCI_REGISTRY_URL`).
  """
  def cyfr_run_registry do
    Application.get_env(:cyfr, :oci_registry_url, @default_cyfr_run_registry)
  end

  @doc """
  Returns the REST API host for cyfr.run (`/v1/*` endpoints: probe,
  namespaces, components, members, tokens).

  Distinct from the OCI Distribution host (see `cyfr_run_registry/0`) on
  Core — REST is `cyfr.run`, OCI is `registry.cyfr.run`. Arx deployments
  can co-host via `CYFR_REGISTRY_URL = CYFR_OCI_REGISTRY_URL`.

  Sourced from `:cyfr, :registry_url` with default `"cyfr.run"`. Unified
  here so callers (`Registry.Client`, `Registry.Identity`) share a single
  source of truth — previously each module had its own `rest_host`/
  `api_base_url` private helper reading the same config.
  """
  @spec rest_host() :: String.t()
  def rest_host do
    Application.get_env(:cyfr, :registry_url, @default_rest_host)
  end

  @doc """
  Returns `true` if the current edition is Core (not Arx).
  """
  @spec core_edition?() :: boolean()
  def core_edition? do
    Application.get_env(:cyfr, :edition, :core) != :arx
  end

  @doc """
  Validates that the given registry is allowed for the current edition.

  Returns `:ok` for Arx edition (any registry allowed) or Core edition
  with `registry.cyfr.run`. Returns `{:error, message}` for Core edition
  with a non-cyfr.run registry.
  """
  @spec validate_registry(String.t()) :: :ok | {:error, String.t()}
  def validate_registry(registry) do
    canonical = cyfr_run_registry()

    if core_edition?() and registry != canonical do
      {:error,
       "Core edition only supports #{canonical}, got: #{registry}. " <>
         "Use Sanctum Arx for custom registries."}
    else
      :ok
    end
  end
end
