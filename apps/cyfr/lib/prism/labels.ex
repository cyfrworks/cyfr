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

  @doc """
  The mode a person without a saved preference sees. On a server with a
  door — an auth provider — everyone but the operators lands in `lite`,
  the chat; a private box, or an operator, gets `dev`.
  """
  @spec default(map() | nil) :: String.t()
  def default(%{platform_admin: true}), do: "dev"
  def default(_ctx), do: if(Sanctum.auth_configured?(), do: "lite", else: "dev")

  @doc "Normalise a stored preference to a mode, falling back to `default/1`."
  @spec mode(term(), map() | nil) :: String.t()
  def mode(mode, _ctx) when mode in @modes, do: mode
  def mode(_, ctx), do: default(ctx)

  @doc "Normalise a mode already resolved for a person (a layout assign)."
  @spec mode(term()) :: String.t()
  def mode(mode) when mode in @modes, do: mode
  def mode(_), do: "dev"

  @doc "The label for `noun` in `mode`."
  @spec label(atom(), String.t()) :: String.t()
  def label(noun, "lite"), do: Map.fetch!(@lite, noun)
  def label(noun, _mode), do: Map.fetch!(@dev, noun)

  @doc "Whether a mode shows the developer views (executions, builds, registry, …)."
  @spec dev?(String.t()) :: boolean()
  def dev?(mode), do: mode(mode) == "dev"
end
