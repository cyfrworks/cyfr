# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.Services do
  @moduledoc """
  The one roster mapping tool-provider modules to the service each
  belongs to. `system.status` derives its scopes and per-service checks
  from this, and the request log's `routed_to` label reads the same map —
  so the same provider cannot be one service in the status report and
  another in the log.
  """

  alias Emissary.MCP.ToolRegistry

  @provider_services %{
    Sanctum.MCP => "sanctum",
    Emissary.MCP.Tools.RecordsProvider => "arca",
    Opus.MCP => "opus",
    Opus.CronMCP => "opus",
    Locus.MCP => "locus",
    Compendium.MCP => "compendium",
    Emissary.MCP.McpServersTool => "emissary",
    Emissary.MCP.Tools.SystemProvider => "emissary"
  }

  @doc "The service a provider module belongs to; an unlisted one is emissary's."
  @spec service_name(module()) :: String.t()
  def service_name(module), do: Map.get(@provider_services, module, "emissary")

  @doc "Every service with at least one configured provider, sorted."
  @spec service_names() :: [String.t()]
  def service_names do
    ToolRegistry.configured_providers()
    |> Enum.map(&service_name/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "The configured providers belonging to one service."
  @spec providers_for(String.t()) :: [module()]
  def providers_for(service) do
    Enum.filter(ToolRegistry.configured_providers(), &(service_name(&1) == service))
  end
end
