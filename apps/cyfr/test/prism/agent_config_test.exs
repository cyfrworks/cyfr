# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.AgentConfigTest do
  # The agent's tool_policy is the athanor's: a chat decision that outlives
  # the turn ("always" / "never") edits that one allowlist in place, and the
  # athanor's definitions come from the shipped template on first read.
  use ExUnit.Case, async: false

  alias Prism.AgentConfig

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "agent_config_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp policy(ctx, name) do
    {:ok, guide} =
      Emissary.MCP.ToolRegistry.call_external("aqua", ctx, %{"action" => "get", "name" => name})

    Prism.AgentConfig.stringify_deep(guide)["tool_policy"]
  end

  test "the shipped roster reads through the overlay — no copy is ever made", %{ctx: ctx} do
    assert is_map(policy(ctx, "aqua"))
    assert {:ok, %{files: 0, bytes: 0}} = Arca.usage(ctx, ["aqua"])
  end

  test "set_tool_auto / drop_tool edit the athanor's allowlist in place", %{ctx: ctx} do
    assert policy(ctx, "aqua")["component.pull"] == "ask"

    :ok = AgentConfig.set_tool_auto(ctx, "aqua", "component.pull")
    assert policy(ctx, "aqua")["component.pull"] == "auto"

    :ok = AgentConfig.drop_tool(ctx, "aqua", "component.pull")
    refute Map.has_key?(policy(ctx, "aqua"), "component.pull")

    # The template on disk is untouched — the edit materialized the one
    # agent file into the athanor's own tree.
    {:ok, raw} =
      Arca.get(
        Sanctum.system_context(),
        Compendium.AquaTemplate.seed_prefix() ++ ["agents", "aqua.md"]
      )

    {:ok, shipped} = Compendium.AquaAgent.parse("aqua", raw)
    assert shipped.tool_policy["component.pull"] == "ask"
  end

  test "put_formula_tool_surface always attaches the policy, never a tool list" do
    # `tool_policy` is the only tool surface: a native-search grant rides in
    # the same map as everything else, and an absent policy becomes the
    # empty (fail-closed) allowlist.
    native = AgentConfig.put_formula_tool_surface(%{"task" => "t"}, %{"native_search" => "auto"})
    assert native["tool_policy"] == %{"native_search" => "auto"}
    refute Map.has_key?(native, "visible_tools")

    mixed =
      AgentConfig.put_formula_tool_surface(%{"task" => "t"}, %{
        "native_search" => "auto",
        "files.read" => "auto"
      })

    assert map_size(mixed["tool_policy"]) == 2

    empty = AgentConfig.put_formula_tool_surface(%{"task" => "t"}, nil)
    assert empty["tool_policy"] == %{}
  end

  test "the system prompt names every guest storage scope", %{ctx: ctx} do
    # The prose in build_dynamic_context is hand-written; this pins it to
    # the vocabulary `Arca.Storage.guest_scopes/0` defines, so a renamed or
    # added guest scope cannot leave the model prompt describing a stale one.
    prompt = AgentConfig.build_system_prompt(ctx)

    for scope <- Map.keys(Arca.Storage.guest_scopes()) do
      assert prompt =~ scope <> "/",
             "system prompt no longer mentions guest scope #{scope}/"
    end
  end
end
