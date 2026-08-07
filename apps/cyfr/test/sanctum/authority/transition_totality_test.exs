# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.TransitionTotalityTest do
  use ExUnit.Case, async: true

  alias Sanctum.Authority
  alias Sanctum.Authority.Transition
  alias Sanctum.Test.AuthorityFixtures, as: Fixtures

  # §6 "Transition relation is total": every (cursor, guest function,
  # target) combination has a defined, asserted outcome. The relation is a
  # literal map with no catch-all, so totality is checked by enumeration —
  # first structurally against the cross product, then behaviorally by
  # driving step/3 through every combination.

  test "the relation enumerates exactly the full cross product" do
    expected =
      for cursor <- Transition.cursor_tags(),
          fun <- Transition.guest_functions(),
          tag <- Transition.target_tags(),
          into: MapSet.new() do
        {cursor, fun, tag}
      end

    assert MapSet.new(Map.keys(Transition.relation())) == expected
    assert map_size(Transition.relation()) == 2 * 8 * 6
  end

  test "every combination steps to an outcome in the closed union" do
    representatives = %{
      invoke:
        Fixtures.invoke("catalyst:supabase.com.database",
          need: "source",
          declared_needs: ["source", "dest"]
        ),
      tool: {:tool, %{tool: "storage", action: "read"}},
      external_tool: {:external_tool, %{server_digest: "sha256:x", tool: "issues_list"}},
      task: {:task, "task_1"},
      tasks: {:tasks, ["task_1"]},
      event: {:event, %{"msg" => "hi"}}
    }

    authorities = %{bound: Fixtures.root!(), unbound: Authority.zero()}

    for {cursor, auth} <- authorities,
        fun <- Transition.guest_functions(),
        {tag, target} <- representatives do
      outcome = Transition.step(auth, fun, target)

      assert valid_outcome?(outcome),
             "undefined outcome for {#{cursor}, #{fun}, #{tag}}: #{inspect(outcome)}"
    end
  end

  test "outcome tags are the pinned closed set" do
    assert Transition.outcome_tags() == [
             :child,
             :child_zero,
             :deny,
             :allow_tool,
             :allow_async,
             :allow_emit,
             :invalid
           ]
  end

  test "terms outside the target vocabulary are caller bugs, not policy outcomes" do
    auth = Fixtures.root!()

    assert_raise ArgumentError, fn -> Transition.step(auth, :call, {:garbage, 1}) end
    assert_raise ArgumentError, fn -> Transition.step(auth, :call, {:task, 42}) end
    assert_raise ArgumentError, fn -> Transition.step(auth, :call, nil) end

    # apply/3 keeps the deliberately-invalid atom out of the type checker.
    assert_raise FunctionClauseError, fn ->
      apply(Transition, :step, [auth, :run, {:task, "task_1"}])
    end
  end

  # The closed outcome union, spelled out.
  defp valid_outcome?({:child, %Authority{}}), do: true
  defp valid_outcome?({:child_zero, %Authority{cursor: :unbound, policy: :none}}), do: true
  defp valid_outcome?({:deny, :depth_cap}), do: true
  defp valid_outcome?({:deny, :invoke_budget_exhausted}), do: true
  defp valid_outcome?({:deny, :edge_only}), do: true
  defp valid_outcome?({:deny, {:need, kind}}), do: kind in [:required, :undeclared]
  defp valid_outcome?({:deny, :tool_not_granted}), do: true
  defp valid_outcome?({:deny, :tool_server_not_granted}), do: true
  defp valid_outcome?({:deny, :unbound_control_plane}), do: true
  defp valid_outcome?({:allow_tool, {:tools, action}}), do: is_binary(action)
  defp valid_outcome?({:allow_tool, {:tool_server, digest}}), do: is_binary(digest)

  defp valid_outcome?({:allow_async, fun}),
    do: fun in [:await, :await_all, :await_any, :poll, :cancel]

  defp valid_outcome?({:allow_emit, {:attributed, node}}), do: is_binary(node)
  defp valid_outcome?({:allow_emit, :untrusted}), do: true

  defp valid_outcome?({:invalid, {:malformed_target, fun, tag}}),
    do: fun in Transition.guest_functions() and tag in Transition.target_tags()

  defp valid_outcome?(_), do: false
end
