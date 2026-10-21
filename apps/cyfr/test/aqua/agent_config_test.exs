# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.AgentConfigTest do
  # The agent's tool_policy is DECLARED policy, read from the athanor's
  # own copy of the shipped template. A chat decision that outlives the
  # turn ("always" / "never") is not an edit to it — those are
  # `Aqua.ToolGrants` rows, composed over the declaration at use time.
  use ExUnit.Case, async: false

  alias Aqua.AgentConfig

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "agent_config_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    :ok = Sanctum.TestContext.shipped!(Sanctum.TestContext.athanor_id())
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp policy(ctx, name) do
    {:ok, guide} =
      Sanctum.Gate.call_external("aqua", ctx, %{"action" => "get", "name" => name})

    Aqua.AgentConfig.stringify_deep(guide)["tool_policy"]
  end

  # Every AQUA unit the athanor holds is an unedited copy of what ships.
  defp pristine?(ctx) do
    {:ok, statuses} = Arca.Overlay.unit_statuses(Sanctum.Context.actor(ctx), "aqua")
    statuses != %{} and Enum.all?(statuses, fn {_unit, status} -> status == :shipped end)
  end

  test "the shipped roster is read from the athanor's own copy", %{ctx: ctx} do
    assert is_map(policy(ctx, "aqua"))
    assert Arca.exists?(Sanctum.Context.actor(ctx), Compendium.AquaPath.agent_file("aqua"))
    assert pristine?(ctx)
  end

  test "a standing decision never rewrites the declared policy", %{ctx: ctx} do
    assert policy(ctx, "aqua")["component.pull"] == "ask"

    {:ok, _} =
      Sanctum.ToolGrants.put(ctx, %{
        scope: "agent",
        effect: "allow",
        agent_name: "aqua",
        tool: "component",
        action: "pull"
      })

    # The agent's own file still says "ask" — a chat click is a decision,
    # not an edit to what the author declared.
    assert policy(ctx, "aqua")["component.pull"] == "ask"

    # And no file in the athanor's tree was edited to say so.
    assert pristine?(ctx)
  end

  test "a catalyst the athanor holds resolves to its newest installed release", %{ctx: ctx} do
    for version <- ["9.0.0", "10.0.0"] do
      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:catalyst), %{
          name: "resolver-model",
          version: version,
          type: "catalyst",
          description: "Test catalyst"
        })
    end

    # `component.list` names a row by `component_ref`. A resolver reading any
    # other key matches nothing, and every installed model reads as missing.
    {:ok, listing} = AgentConfig.catalyst_listing(ctx)

    assert {:ok, "catalyst:local.resolver-model:10.0.0"} =
             AgentConfig.resolve_catalyst(listing, "catalyst:local.resolver-model")

    assert {:error, :catalyst_not_found} =
             AgentConfig.resolve_catalyst(listing, "catalyst:local.absent")
  end
end
