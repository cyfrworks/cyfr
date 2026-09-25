# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Kinds do
  @moduledoc """
  What an operation is to the assistant: its kind, whether it may ever
  run without a card, the verbs a tool has, and whether a chat can run
  it at all — read from the catalog's annotations and the virtual-tool
  catalog, one rule for the AQUA page and the runtime ceiling alike. The
  classification is the gate's (`Grimoire.tool_kind/2`,
  `Grimoire.tool_actions/1`), which the `aqua` tool's door in the
  component domain (`Compendium.AquaAgent.validate_tool_policy/2`) reads
  too.
  """

  @doc """
  The kind of `tool.action` — the gate's one classification
  (`Grimoire.tool_kind/2`): a virtual hand's kind, `:external` for a
  `server:tool`, else the catalogued tool's declared kind, nil when
  unknown.
  """
  @spec kind_for(String.t(), String.t()) :: atom() | nil
  defdelegate kind_for(tool, action), to: Grimoire, as: :tool_kind

  @doc """
  Whether `tool.action` may ever run without a card: only a read, write or
  execute kind. Destructive and external actions always ask, and an
  action whose kind is unknown is refused too — "not known" and "not yet
  loaded" read the same here, and only the second could otherwise run
  something destructive with no card. The one rule the AQUA page and the
  runtime ceiling (`Aqua.ToolGrants.effective/2`) read; the kinds it admits
  are `Prima.VirtualTools.auto_permitted_kinds/0`.
  """

  @spec auto_permitted?(String.t(), String.t()) :: boolean()

  def auto_permitted?(tool, action),
    do: Prima.VirtualTools.auto_permitted_kind?(kind_for(tool, action))

  @doc """
  The action verbs a catalogued tool has — the virtual catalog's for a
  virtual tool, the registry's `action` enum otherwise — and `[]` for a
  tool neither holds. What a `tool.*` glob stands for.
  """

  @spec actions_of(String.t()) :: [String.t()]
  defdelegate actions_of(tool), to: Grimoire, as: :tool_actions

  @doc "Whether the virtual catalog or the registry holds a tool of this name."

  @spec catalogued?(String.t()) :: boolean()

  def catalogued?(tool) when is_binary(tool),
    do: Prima.VirtualTools.tool?(tool) or actions_of(tool) != []

  def catalogued?(_tool), do: false

  # The standing rule of a tool.action, from the same declaration `kind_for/2`

  # reads. The virtual catalog and the external namespace declare none, so

  # both keep the default (any standing scope); an internal tool answers

  # from its registry annotation.

  @spec standing_for(String.t(), String.t()) :: :thread | false | nil

  def standing_for(tool, action) when is_binary(tool) and is_binary(action) do
    cond do
      Prima.VirtualTools.tool?(tool) -> nil
      String.contains?(tool, ":") -> nil
      true -> Aqua.Ops.action_standing(tool, action)
    end
  end

  def standing_for(_, _), do: nil

  # An approved proposal is executed inside the chain, so an action that

  # plane refuses is not worth offering — the card would fail on the click.

  # Only a refusal the registry actually asserts counts: a virtual tool (the

  # formula dispatches those itself) and a `tool.*` glob stand, and so does

  # anything the registry has never heard of.

  @doc "Whether a `tool.action` an allowlist marks `ask` is one a card can run."
  @spec proposable?(String.t()) :: boolean()
  def proposable?(key), do: not refused?(key) and not auto_only?(key)

  defp auto_only?(key) do
    case String.split(key, ".", parts: 2) do
      [tool, action] -> Prima.VirtualTools.auto_only?(tool, action)
      _ -> false
    end
  end

  defp refused?(key) do
    case String.split(key, ".", parts: 2) do
      [_tool, "*"] -> false
      [tool, action] -> refused?(tool, action)
      _ -> false
    end
  end

  @doc "Whether a chat would refuse `tool.action` outright."
  @spec refused?(String.t(), String.t()) :: boolean()
  def refused?(tool, action) do
    if Prima.VirtualTools.tool?(tool) do
      is_nil(Prima.VirtualTools.kind_for(tool, action))
    else
      Aqua.Ops.in_chain_refused?(tool, action)
    end
  end
end
