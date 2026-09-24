# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.Services do
  @moduledoc """
  The service vocabulary over the tool providers. Each provider declares
  its own service (`c:Prima.Provider.service/0`); this module
  only aggregates — `system.status` derives its scopes and per-service
  checks from the same answers the request log's `routed_to` label reads.
  """

  alias Cyfr.Ops.Catalog

  require Logger

  @doc """
  The service a provider module belongs to — asked of the module itself
  (`c:Prima.Provider.service/0`), so a provider cannot be one
  service in the status report and another in the log, and a renamed
  module cannot silently fall out of a central map. A module that answers
  nothing is labeled emissary's, LOUDLY — that fallback is a defect, not
  a default.
  """
  @spec service_name(module()) :: String.t()
  def service_name(module) do
    case :persistent_term.get({__MODULE__, module}, nil) do
      nil ->
        case resolve_service_name(module) do
          {:ok, name} ->
            :persistent_term.put({__MODULE__, module}, name)
            name

          # The loud fallback is never pinned: a module that answers
          # nothing NOW (a load-order gap) may answer on the next call.
          {:fallback, name} ->
            name
        end

      name ->
        name
    end
  end

  # Cache the service label derived from the provider set fixed at boot.
  defp resolve_service_name(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :service, 0) do
      {:ok, module.service()}
    else
      Logger.error(
        "[Cyfr.Ops.Services] provider #{inspect(module)} exports no service/0 — " <>
          "labeling as \"emissary\"; declare `service/0` on the provider"
      )

      {:fallback, "emissary"}
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
