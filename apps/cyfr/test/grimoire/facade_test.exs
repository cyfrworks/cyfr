# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.FacadeTest do
  @moduledoc """
  The gate's door for callers outside it is an exact roster: an entry
  added without a roster change fails here. The refusal, annotation,
  resource and visibility entries answer as the internals they name do.
  """

  use ExUnit.Case, async: true

  @roster [
    annotation_kind: 2,
    annotation_recovery: 2,
    annotation_standing: 2,
    call_external: 3,
    call_external: 4,
    call_in_chain: 4,
    call_in_chain: 5,
    cancel_call: 1,
    cancel_request: 1,
    chain_reachable?: 2,
    classify: 1,
    close_decision: 3,
    code_override: 1,
    configured_providers: 0,
    declared_actions: 1,
    get_tool: 1,
    host_intercepted?: 2,
    host_intercepted_actions: 0,
    in_chain_refused?: 2,
    list_resource_templates: 0,
    list_resources: 0,
    list_tools: 0,
    lookup: 1,
    open_decision: 2,
    open_decision: 3,
    operations: 0,
    refused_decision: 3,
    release_call: 1,
    render: 1,
    resolve_resource: 1,
    resources: 0,
    restrict_tool: 2,
    standing_scope: 1,
    standing_to_wire: 1,
    visible_tools: 2
  ]

  # One action map, in the provider's atom-keyed spelling and the wire's
  # string-keyed one.
  @actions %{
    "read" => %{kind: :read, recovery: :replay_safe, standing: :thread},
    "write" => %{kind: :write, recovery: :replay_safe, standing: false}
  }

  test "the root answers exactly its roster" do
    exported =
      Grimoire.__info__(:functions)
      |> Enum.reject(fn {name, _arity} -> name in [:__info__, :module_info] end)
      |> Enum.sort()

    assert exported == @roster
  end

  test "a refusal classifies and overrides as Grimoire.Error does" do
    for reason <- [:not_found, {:forbidden, "no"}, "free text", :unauthorized] do
      refusal = Grimoire.classify(reason)
      assert refusal == Grimoire.Error.classify(reason)
      assert Grimoire.code_override(refusal) == Grimoire.Error.code_override(refusal)
    end
  end

  test "annotations read as Grimoire.Annotations reads them, in either spelling" do
    for source <- [%{annotations: %{actions: @actions}}, %{"annotations" => %{actions: @actions}}] do
      assert Grimoire.declared_actions(source) == @actions
      assert Grimoire.annotation_kind(source, "read") == :read
      assert Grimoire.annotation_kind(source, "nope") == nil
      assert Grimoire.annotation_standing(source, "read") == :thread
      assert Grimoire.annotation_standing(source, "write") == false
      assert Grimoire.annotation_recovery(source, "read") == :replay_safe
      # A write annotated replay-safe is not.
      assert Grimoire.annotation_recovery(source, "write") == nil
    end

    assert Grimoire.declared_actions(%{}) == %{}

    for value <- [:thread, "thread", false, nil, "always"] do
      assert Grimoire.standing_scope(value) == Grimoire.Annotations.standing(value)
      assert Grimoire.standing_to_wire(value) == Grimoire.Annotations.standing_to_wire(value)
    end
  end

  test "resources list and resolve as Grimoire.Resources does" do
    assert Grimoire.list_resources() == Grimoire.Resources.list_resources()
    assert Grimoire.list_resource_templates() == Grimoire.Resources.list_resource_templates()

    assert Grimoire.resolve_resource("nothing://here") ==
             Grimoire.Resources.resolve("nothing://here")
  end

  test "visibility filters as Grimoire.Visibility does" do
    ctx = Sanctum.TestContext.local()
    anonymous = %{ctx | authenticated: false}
    tools = Grimoire.list_tools()

    for caller <- [ctx, anonymous] do
      assert Grimoire.visible_tools(tools, caller) ==
               Grimoire.Visibility.filter_for_context(tools, caller)
    end
  end
end
