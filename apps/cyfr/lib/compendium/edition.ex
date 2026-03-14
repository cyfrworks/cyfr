defmodule Compendium.Edition do
  @moduledoc """
  Edition-aware registry enforcement for Compendium.

  Core edition (the default) restricts all OCI operations to `registry.cyfr.run`.
  Sanctum Arx edition allows any registry.
  """

  @cyfr_run_registry "registry.cyfr.run"

  @doc """
  Returns the canonical CYFR registry hostname.
  """
  def cyfr_run_registry, do: @cyfr_run_registry

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
    if core_edition?() and registry != @cyfr_run_registry do
      {:error, "Core edition only supports registry.cyfr.run, got: #{registry}. " <>
               "Use Sanctum Arx for custom registries."}
    else
      :ok
    end
  end
end
