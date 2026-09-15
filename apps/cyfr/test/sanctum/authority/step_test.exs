# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.StepTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cyfr.Authority
  alias Cyfr.Authority.Transition
  alias Cyfr.Test.AuthorityFixtures, as: Fixtures
  alias Sanctum.Test.AuthorityGen, as: Gen

  # `Sanctum.Authority.step/3` is the transition relation with the root
  # invoke budget charged for every spawn that starts work.

  @catalyst "catalyst:supabase.com.database"

  defp tool(name, action), do: {:tool, %{tool: name, action: action}}
  defp external(digest, tool), do: {:external_tool, %{server_digest: digest, tool: tool}}

  # ============================================================================
  # Root budget (spawn only)
  # ============================================================================

  describe "spawn budget" do
    test "spawn charges the root budget; call does not" do
      auth = Fixtures.root!(%{}, ceiling: %{max_concurrent_tasks: 2})

      # Synchronous calls never consume budget.
      for _ <- 1..5 do
        assert {:child, _} =
                 Sanctum.Authority.step(
                   auth,
                   :call,
                   Fixtures.invoke(@catalyst,
                     need: "source",
                     declared_needs: Fixtures.formula_needs()
                   )
                 )
      end

      assert Sanctum.Authority.budget(auth).in_flight == 0

      assert {:child_zero, _} =
               Sanctum.Authority.step(auth, :spawn, Fixtures.invoke("formula:local.a"))

      assert {:child_zero, _} =
               Sanctum.Authority.step(auth, :spawn, Fixtures.invoke("formula:local.b"))

      assert {:deny, :invoke_budget_exhausted} =
               Sanctum.Authority.step(auth, :spawn, Fixtures.invoke("formula:local.c"))

      Sanctum.Authority.release_invoke(auth)

      assert {:child_zero, _} =
               Sanctum.Authority.step(auth, :spawn, Fixtures.invoke("formula:local.c"))
    end

    test "the budget is root-keyed: children spend the same pool" do
      auth = Fixtures.root!(%{}, ceiling: %{max_concurrent_tasks: 2})

      {:child_zero, child} =
        Sanctum.Authority.step(auth, :spawn, Fixtures.invoke("formula:local.a"))

      # One slot is held by the spawn above; the child's own spawn takes
      # the second; a grandchild spawn then exhausts the ROOT's pool.
      {:child_zero, grandchild} =
        Sanctum.Authority.step(child, :spawn, Fixtures.invoke("formula:local.b"))

      assert {:deny, :invoke_budget_exhausted} =
               Sanctum.Authority.step(grandchild, :spawn, Fixtures.invoke("formula:local.c"))

      assert Sanctum.Authority.budget(auth) == %{in_flight: 2, cap: 2}
    end

    test "a denied spawn consumes nothing" do
      auth = Fixtures.root!(%{}, ceiling: %{max_concurrent_tasks: 1})

      for _ <- 1..3 do
        assert {:deny, {:need, :required}} =
                 Sanctum.Authority.step(
                   auth,
                   :spawn,
                   Fixtures.invoke(@catalyst, declared_needs: Fixtures.formula_needs())
                 )
      end

      assert Sanctum.Authority.budget(auth).in_flight == 0

      assert {:child_zero, _} =
               Sanctum.Authority.step(auth, :spawn, Fixtures.invoke("formula:local.a"))
    end

    test "async functions and malformed spawns never touch the budget" do
      auth = Fixtures.root!(%{}, ceiling: %{max_concurrent_tasks: 1})

      Sanctum.Authority.step(auth, :await, {:task, "task_1"})
      Sanctum.Authority.step(auth, :poll, {:task, "task_1"})
      Sanctum.Authority.step(auth, :spawn, {:event, %{"msg" => "hi"}})

      assert Sanctum.Authority.budget(auth).in_flight == 0
    end
  end

  # ============================================================================
  # Spawned tool dispatch charges the root budget
  # ============================================================================

  describe "spawn budget on tools" do
    test "a spawned tool dispatch takes a slot; a denied one does not" do
      auth = Fixtures.root!(%{}, ceiling: %{max_concurrent_tasks: 1})

      assert {:deny, :tool_not_granted} =
               Sanctum.Authority.step(auth, :spawn, tool("storage", "write"))

      assert Sanctum.Authority.budget(auth).in_flight == 0

      assert {:allow_tool, _} = Sanctum.Authority.step(auth, :spawn, tool("storage", "read"))
      assert Sanctum.Authority.budget(auth).in_flight == 1

      assert {:deny, :invoke_budget_exhausted} =
               Sanctum.Authority.step(auth, :spawn, tool("storage", "read"))

      Sanctum.Authority.release_invoke(auth)

      assert {:allow_tool, _} =
               Sanctum.Authority.step(
                 auth,
                 :spawn,
                 external(Fixtures.server_digest(), "repo_get")
               )
    end

    test "a synchronous tool call never consumes budget" do
      auth = Fixtures.root!(%{}, ceiling: %{max_concurrent_tasks: 1})

      for _ <- 1..5 do
        assert {:allow_tool, _} = Sanctum.Authority.step(auth, :call, tool("storage", "read"))
      end

      assert Sanctum.Authority.budget(auth).in_flight == 0
    end
  end

  # ============================================================================
  # Totality under the charge
  # ============================================================================

  property "randomized authorities, functions and targets stay inside the closed union" do
    check all(
            {graph, meta} <- Gen.graph(),
            fun <- member_of(Transition.guest_functions()),
            target <- Gen.target(meta),
            descend <- integer(0..3),
            max_runs: 100
          ) do
      root = Gen.rooted({graph, meta})

      auth =
        Enum.reduce(List.duplicate(:down, descend), root, fn :down, acc ->
          need = Gen.compliant_need(acc, meta)

          case Transition.step(acc, :call, Gen.invoke_at(acc, meta, "formula:evil.corp.w", need)) do
            {:child_zero, child} -> child
            _ -> acc
          end
        end)

      outcome = Sanctum.Authority.step(auth, fun, target)

      assert valid_outcome?(outcome),
             "undefined outcome for {#{inspect(auth.cursor)}, #{fun}}: #{inspect(outcome)}"
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
