# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Kinds do
  @moduledoc """
  What an operation is to the assistant: its kind, whether it may ever
  run without a card, the verbs a tool has, and whether a chat can run
  it at all — read from the catalog's annotations and the virtual-tool
  catalog, one rule for the AQUA page, the `aqua` tool's door and the
  runtime ceiling alike.
  """

  # Resolve the kind of a tool.action.
  #

  # 1. AQUA virtual-tool catalog (`files`/`storage`/`http`/`request_setup`).

  # 2. External upstream MCP tools are namespaced `server:tool` and have no

  #    enumerable action verbs — short-circuit to `:external` regardless of

  #    the action arg.

  # 3. Internal cyfr tools must declare `kind` per action in

  #    `annotations.actions[verb].kind`. No `_default` fallback — a missing

  #    annotation returns `nil` so the gap is visible (and caught by the

  #    `audit_action_kinds/0` startup check).

  @spec kind_for(String.t(), String.t()) :: atom() | nil

  def kind_for(tool, action) when is_binary(tool) and is_binary(action) do
    cond do
      kind = Aqua.Hands.kind_for(tool, action) ->
        kind

      String.contains?(tool, ":") ->
        :external

      true ->
        lookup_internal_kind(tool, action)
    end
  end

  def kind_for(_, _), do: nil

  defp lookup_internal_kind(tool, action), do: Aqua.Ops.action_kind(tool, action)

  @auto_kinds [:read, :write, :execute]

  @doc """
  Whether `tool.action` may ever run without a card: only a read, write or
  execute kind. Destructive and external actions always ask, and an
  action whose kind is unknown is refused too — "not known" and "not yet
  loaded" read the same here, and only the second could otherwise run
  something destructive with no card. The one rule the AQUA page, the
  `aqua` tool's door and the runtime ceiling (`Aqua.ToolGrants.effective/2`)
  all read.
  """

  @spec auto_permitted?(String.t(), String.t()) :: boolean()

  def auto_permitted?(tool, action), do: kind_for(tool, action) in @auto_kinds

  @doc """
  The action verbs a catalogued tool has — the virtual catalog's for a
  virtual tool, the registry's `action` enum otherwise — and `[]` for a
  tool neither holds. What a `tool.*` glob stands for.
  """

  @spec actions_of(String.t()) :: [String.t()]

  def actions_of(tool) when is_binary(tool) do
    if Aqua.Hands.hand?(tool),
      do: Aqua.Hands.actions_of(tool),
      else: Aqua.Ops.actions_of(tool)
  end

  def actions_of(_tool), do: []

  @doc "Whether the virtual catalog or the registry holds a tool of this name."

  @spec catalogued?(String.t()) :: boolean()

  def catalogued?(tool) when is_binary(tool),
    do: Aqua.Hands.hand?(tool) or actions_of(tool) != []

  def catalogued?(_tool), do: false

  # The standing rule of a tool.action, from the same declaration `kind_for/2`

  # reads. The virtual catalog and the external namespace declare none, so

  # both keep the default (any standing scope); an internal tool answers

  # from its registry annotation.

  @spec standing_for(String.t(), String.t()) :: :conversation | false | nil

  def standing_for(tool, action) when is_binary(tool) and is_binary(action) do
    cond do
      Aqua.Hands.hand?(tool) -> nil
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
      [tool, action] -> Aqua.Hands.auto_only?(tool, action)
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
    if Aqua.Hands.hand?(tool) do
      is_nil(Aqua.Hands.kind_for(tool, action))
    else
      Aqua.Ops.in_chain_refused?(tool, action)
    end
  end
end
