# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Manifest do
  @moduledoc """
  The component domain's manifest vocabulary: the suggested categories.

  What a manifest may declare, its contracts and the one validator every
  write boundary runs are the shared contract `Prima.Manifest`.
  """

  @doc """
  The suggested vocabulary for the manifest's `category` field — the one
  roster the MCP categories action serves. The field itself is free
  text (search filters on whatever a manifest declared); this names the
  recommended values without enforcing them.
  """
  @spec known_categories() :: [%{name: String.t(), description: String.t()}]
  def known_categories do
    [
      %{name: "api-integrations", description: "External API connectors"},
      %{name: "data-processing", description: "Data transformation and analysis"},
      %{name: "ai-ml", description: "Machine learning and AI tools"},
      %{name: "security", description: "Security and cryptography"},
      %{name: "utilities", description: "General-purpose utilities"}
    ]
  end
end
