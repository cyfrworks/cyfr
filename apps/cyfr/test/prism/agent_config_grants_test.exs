# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.AgentConfigGrantsTest do
  # Per-user approval grants: the "always"/"never" chat decisions are a
  # personal overlay in tenant-scoped storage, never a mutation of the
  # instance-global agent.json. One user's click must not change what the
  # agent may do for anyone else.
  use ExUnit.Case, async: false

  alias Prism.AgentConfig
  alias Sanctum.Context

  setup do
    test_path = Path.join(System.tmp_dir!(), "agent_grants_#{:rand.uniform(1_000_000)}")
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

  defp user_ctx(user_id) do
    Context.build(
      user_id: user_id,
      provider: "local",
      athanor_id: Sanctum.TestContext.athanor_id(),
      permissions: [:execute],
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  test "grants round-trip and merge into the effective policy", %{ctx: ctx} do
    assert AgentConfig.user_tool_grants(ctx, "aqua") == %{}

    :ok = AgentConfig.put_user_tool_grant(ctx, "aqua", "component.list", "auto")
    :ok = AgentConfig.put_user_tool_grant(ctx, "aqua", "webhook.create", "deny")

    assert AgentConfig.user_tool_grants(ctx, "aqua") == %{
             "component.list" => "auto",
             "webhook.create" => "deny"
           }

    manifest_policy = %{"webhook.create" => "ask", "execution.run" => "ask"}
    effective = AgentConfig.effective_tool_policy(ctx, "aqua", manifest_policy)

    # "auto" is added, "deny" removes the key (absence = not callable),
    # untouched manifest entries pass through.
    assert effective == %{"component.list" => "auto", "execution.run" => "ask"}
  end

  test "grants are per-user and per-agent", %{ctx: ctx} do
    :ok = AgentConfig.put_user_tool_grant(ctx, "aqua", "component.list", "auto")

    other_user = user_ctx("local|local|someoneelse")
    assert AgentConfig.user_tool_grants(other_user, "aqua") == %{}

    assert AgentConfig.user_tool_grants(ctx, "other-agent") == %{}
    assert AgentConfig.effective_tool_policy(other_user, "aqua", %{}) == %{}
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
