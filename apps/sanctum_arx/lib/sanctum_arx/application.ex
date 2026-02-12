# SPDX-License-Identifier: FSL-1.1-MIT
# Copyright 2024 CYFR Inc. All Rights Reserved.

defmodule SanctumArx.Application do
  @moduledoc """
  SanctumArx OTP Application.

  Handles startup initialization including license validation for Arx edition.
  This application depends on base Sanctum and extends it with enterprise features.
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Load and validate license before starting supervision tree
    load_license()

    children = [
      # Enterprise-specific workers can be added here
      # {SanctumArx.Vault.Client, []},
      # {SanctumArx.SIEM.Forwarder, []},
    ]

    opts = [strategy: :one_for_one, name: SanctumArx.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # ============================================================================
  # License Loading
  # ============================================================================

  defp load_license do
    case SanctumArx.License.load() do
      {:ok, :community} ->
        Logger.info("[SanctumArx] Starting in community mode (no Arx license)")

      {:ok, license} ->
        Logger.info("[SanctumArx] Starting in Sanctum Arx edition",
          customer_id: license.customer_id,
          expires_at: DateTime.to_iso8601(license.expires_at)
        )

      {:error, :expired} ->
        # Zombie mode - license expired but we continue running
        Logger.warning(
          "[SanctumArx] Arx license expired - running in zombie mode. " <>
            "Some features may be restricted. Please renew your license."
        )

      {:error, {:license_file_missing, path}} ->
        if SanctumArx.License.edition() == :arx do
          Logger.error(
            "[SanctumArx] Arx edition configured but license file not found at #{path}. " <>
              "Please provide a valid license file or switch to Sanctum."
          )
        end

      {:error, reason} ->
        Logger.error("[SanctumArx] License validation failed: #{inspect(reason)}")
    end
  end
end
