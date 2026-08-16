# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.Labels do
  @moduledoc """
  The words Prism uses for its nouns, per UI mode.

  A person chooses `"lite"` or `"dev"` in Settings (`users.prefs["mode"]`).
  Dev speaks the runtime's own vocabulary; lite speaks the everyday one —
  the same page, the same tool calls, different labels. MCP server stays
  "MCP server" in both: it is a proper name, not jargon.
  """

  @modes ~w(lite dev)
  @default "dev"

  @lite %{
    tincture: "App",
    tinctures: "Apps",
    execution: "Task run",
    executions: "Task runs",
    formula: "Workflow",
    formulas: "Workflows",
    reagent: "Integration",
    reagents: "Integrations",
    catalyst: "AI model",
    catalysts: "AI models",
    component: "Building block",
    components: "Building blocks"
  }

  @dev %{
    tincture: "Tincture",
    tinctures: "Tinctures",
    execution: "Execution",
    executions: "Executions",
    formula: "Formula",
    formulas: "Formulas",
    reagent: "Reagent",
    reagents: "Reagents",
    catalyst: "Catalyst",
    catalysts: "Catalysts",
    component: "Component",
    components: "Components"
  }

  @doc "The recognised modes."
  def modes, do: @modes

  @doc "The mode a person without a saved preference sees."
  def default, do: @default

  @doc "Normalise a stored preference to a mode."
  @spec mode(term()) :: String.t()
  def mode(mode) when mode in @modes, do: mode
  def mode(_), do: @default

  @doc "The label for `noun` in `mode`."
  @spec label(atom(), String.t()) :: String.t()
  def label(noun, "lite"), do: Map.fetch!(@lite, noun)
  def label(noun, _mode), do: Map.fetch!(@dev, noun)

  @doc "Whether a mode shows the developer views (executions, builds, registry, …)."
  @spec dev?(String.t()) :: boolean()
  def dev?(mode), do: mode(mode) == "dev"
end
