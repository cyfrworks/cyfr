# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.AquaTemplatePolicyTest do
  @moduledoc """
  The shipped soul is offered only what a chat can actually run.

  A turn's calls run inside the chain (`Aqua.Loop`), so a `tools` entry
  whose action the chain cannot reach is a call Aqua is told it may make
  and then cannot. Those actions live on their own pages, where a member
  does them as themselves.
  """
  use ExUnit.Case, async: true

  alias Aqua.Hands

  @seed Path.expand("../../../../seed/aqua", __DIR__)

  test "every tool the shipped soul is offered is reachable from a chat" do
    # The check refuses an action a virtual tool does not have.
    assert refused?("storage.frobnicate")

    {:ok, soul} =
      Compendium.AquaAgent.parse("aqua", File.read!(Path.join(@seed, "aqua.md")))

    assert soul.tools != []
    unreachable = soul.tools |> Enum.filter(&refused?/1) |> Enum.sort()

    assert unreachable == [],
           "the shipped soul is offered actions a running chain cannot reach:\n" <>
             Enum.join(unreachable, "\n")
  end

  # The "execution" entries come from Opus.Provider's registered tool.
  test "the capability matrix offers reachable actions, with their real kinds" do
    catalog = Map.new(PrismWeb.AquaLive.Catalog.enumerate_tool_actions())

    # A real kind, not the `:write` default a missing annotation falls back to.
    assert {"run", :execute} in catalog["execution"]
    assert {"list", :read} in catalog["execution"]

    # ...and nothing the chain would refuse at the call.
    refute Enum.any?(catalog["execution"] || [], &(elem(&1, 0) == "status"))
    refute Map.has_key?(catalog, "door")
    refute Map.has_key?(catalog, "member")
  end

  # `native_search` is a bare exclusivity gate, not a tool; a `tool.*` glob
  # is offered as the tool's own actions (`Aqua.Offered`); an outside
  # server's `server:tool` names no catalogued action.
  defp refused?("native_search"), do: false

  defp refused?(key) do
    case String.split(key, ".", parts: 2) do
      [_tool, "*"] ->
        false

      [tool, action] ->
        if Hands.hand?(tool) do
          # A virtual tool's ACTION has to exist too. Accepting the whole
          # namespace on the strength of its name let `storage.frobnicate`
          # through — offered in the template, dispatched by nothing.
          is_nil(Sanctum.VirtualTools.kind_for(tool, action))
        else
          refused_action?(tool, action)
        end

      _ ->
        false
    end
  end

  defp refused_action?(tool, action),
    do:
      match?({:ok, _}, Sanctum.Catalog.get_tool(tool)) and
        not Sanctum.Catalog.chain_reachable?(tool, action)
end
