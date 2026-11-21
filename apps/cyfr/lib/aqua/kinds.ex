# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Kinds do
  @moduledoc """
  What an operation is to the assistant: its kind and the verbs a tool
  has — read from the catalog's annotations and the virtual-tool
  catalog, one rule for the Aqua page and the runtime alike: reads run
  beside each other (`Aqua.Loop.Policy.overlap/1`). The classification is the gate's (`Sanctum.Catalog.tool_kind/2`,
  `Sanctum.Catalog.tool_actions/1`).
  """

  @doc """
  The kind of `tool.action` — the gate's one classification
  (`Sanctum.Catalog.tool_kind/2`): a virtual hand's kind, `:external` for a
  `server:tool`, else the catalogued tool's declared kind, nil when
  unknown.
  """
  @spec kind_for(String.t(), String.t()) :: atom() | nil
  defdelegate kind_for(tool, action), to: Sanctum.Catalog, as: :tool_kind

  @doc """
  The action verbs a catalogued tool has — the virtual catalog's for a
  virtual tool, the registry's `action` enum otherwise — and `[]` for a
  tool neither holds: an entry of the soul's `tools` naming an action
  outside it is offered nothing (`Aqua.Offered`).
  """
  @spec actions_of(String.t()) :: [String.t()]
  defdelegate actions_of(tool), to: Sanctum.Catalog, as: :tool_actions

  @doc "Whether the virtual catalog or the registry holds a tool of this name."
  @spec catalogued?(String.t()) :: boolean()
  def catalogued?(tool) when is_binary(tool),
    do: Sanctum.VirtualTools.tool?(tool) or actions_of(tool) != []

  def catalogued?(_tool), do: false
end
