# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Services do
  @moduledoc """
  The service vocabulary over the tool providers. Each provider declares
  its own service (`c:Prima.Provider.service/0`); this module
  only aggregates — `system.status` derives its scopes and per-service
  checks from the same answers the request log's `routed_to` label reads.
  """

  alias Sanctum.Catalog

  @doc """
  The service a provider module belongs to — asked of the module itself
  (`c:Prima.Provider.service/0`), so a provider cannot be one
  service in the status report and another in the log, and a renamed
  module cannot silently fall out of a central map.
  """
  @spec service_name(module()) :: String.t()
  def service_name(module) do
    case :persistent_term.get({__MODULE__, module}, nil) do
      nil ->
        name = module.service()
        :persistent_term.put({__MODULE__, module}, name)
        name

      name ->
        name
    end
  end

  @doc "Every service with at least one configured provider, sorted."
  @spec service_names() :: [String.t()]
  def service_names do
    Catalog.configured_providers()
    |> Enum.map(&service_name/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "The configured providers belonging to one service."
  @spec providers_for(String.t()) :: [module()]
  def providers_for(service) do
    Enum.filter(Catalog.configured_providers(), &(service_name(&1) == service))
  end
end
