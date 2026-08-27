# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.AquaTemplatePolicyTest do
  @moduledoc """
  The shipped agent allowlist offers only what a chat can actually run.

  An approved proposal is executed inside the chain (`Prism.AquaTurn.run_approved/2`),
  so an allowlist key whose action the chain cannot reach is a card that
  fails on the click — and an `"auto"` key of the same shape is a tool call
  the agent is told it may make and then cannot. Those actions live on their
  own pages, where a member does them as themselves.
  """
  use ExUnit.Case, async: true

  alias Emissary.MCP.ToolRegistry
  alias Prism.AquaVirtualTools

  @agents_dir Path.expand("../../../../seed/aqua/agents", __DIR__)

  test "every tool_policy key in the shipped template is reachable from a chat" do
    unreachable =
      @agents_dir
      |> policies()
      |> Enum.flat_map(fn {agent, policy} ->
        for {key, _mode} <- policy, refused?(key), do: "#{agent}: #{key}"
      end)
      |> Enum.sort()

    assert unreachable == [],
           "the shipped allowlist offers actions a running chain cannot reach:\n" <>
             Enum.join(unreachable, "\n")
  end

  # The "execution" entries come from Opus.MCP's registered tool — an
  # app-scoped run has no Opus modules, so the registry has nothing to
  # enumerate under that name.
  @tag :requires_opus_modules
  test "the capability matrix offers reachable actions, with their real kinds" do
    catalog = Map.new(PrismWeb.AgentsLive.Catalog.enumerate_tool_actions())

    # A real kind, not the `:write` default a missing annotation falls back to.
    assert {"run", :execute} in catalog["execution"]
    assert {"list", :read} in catalog["execution"]

    # ...and nothing the chain would refuse at the call.
    refute Enum.any?(catalog["execution"] || [], &(elem(&1, 0) == "force_release"))
    refute Map.has_key?(catalog, "door")
    refute Map.has_key?(catalog, "member")
  end

  defp policies(dir) do
    for file <- File.ls!(dir),
        String.ends_with?(file, ".md"),
        name = String.trim_trailing(file, ".md"),
        {:ok, agent} = Compendium.AquaAgent.parse(name, File.read!(Path.join(dir, file))),
        map_size(agent.tool_policy) > 0,
        do: {agent.name, agent.tool_policy}
  end

  # `native_search` is a bare exclusivity gate, not a tool; a `tool.*` glob
  # is judged per action at proposal time; a sub-agent name is a delegation
  # target the formula resolves itself.
  defp refused?("native_search"), do: false

  defp refused?(key) do
    case String.split(key, ".", parts: 2) do
      [_tool, "*"] -> false
      [tool, action] -> not AquaVirtualTools.virtual_tool?(tool) and refused_action?(tool, action)
      _ -> false
    end
  end

  defp refused_action?(tool, action), do: ToolRegistry.in_chain_refused?(tool, action)
end
