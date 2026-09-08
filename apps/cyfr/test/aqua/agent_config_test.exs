# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.AgentConfigTest do
  # The agent's tool_policy is DECLARED policy, and the athanor's
  # definitions come from the shipped template on first read. A chat
  # decision that outlives the turn ("always" / "never") is not an edit to
  # it — those are `Aqua.ToolGrants` rows, composed over the declaration at
  # use time.
  use ExUnit.Case, async: false

  alias Aqua.AgentConfig

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

    Aqua.AgentConfig.stringify_deep(guide)["tool_policy"]
  end

  test "the shipped roster reads through the overlay — no copy is ever made", %{ctx: ctx} do
    assert is_map(policy(ctx, "aqua"))
    assert {:ok, %{files: 0, bytes: 0}} = Arca.usage(ctx, ["aqua"])
  end

  test "a standing decision never rewrites the declared policy", %{ctx: ctx} do
    assert policy(ctx, "aqua")["component.pull"] == "ask"

    {:ok, _} =
      Aqua.ToolGrants.put(ctx, %{
        scope: "agent",
        effect: "allow",
        agent_name: "aqua",
        tool: "component",
        action: "pull"
      })

    # The agent's own file still says "ask" — a chat click is a decision,
    # not an edit to what the author declared.
    assert policy(ctx, "aqua")["component.pull"] == "ask"

    # And nothing was materialized into the athanor's tree to say so.
    assert {:ok, %{files: 0, bytes: 0}} = Arca.usage(ctx, ["aqua"])
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
end
