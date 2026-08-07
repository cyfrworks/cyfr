# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.DepthBudgetPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sanctum.Authority
  alias Sanctum.Authority.Transition
  alias Sanctum.Test.AuthorityGen, as: Gen

  # §6 "Depth + budget": the depth cap fires at exactly depth_cap on any
  # graph, and the invoke budget is root-keyed — spawns anywhere in the
  # tree drain one shared pool that never resets per level.

  property "any chain denies at exactly the depth cap" do
    check all {graph, meta} <- Gen.graph(), max_runs: 30 do
      auth = Gen.rooted({graph, meta})
      cap = Authority.depth_cap()

      final =
        Enum.reduce(1..cap, auth, fn i, acc ->
          need = Gen.compliant_need(acc, meta)

          {:child_zero, child} =
            Transition.step(acc, :call, Gen.invoke_at(acc, meta, "formula:evil.corp.d#{i}", need))

          child
        end)

      assert final.depth == cap

      assert {:deny, :depth_cap} =
               Transition.step(
                 final,
                 :call,
                 Gen.invoke_at(final, meta, "formula:evil.corp.overflow", nil)
               )
    end
  end

  property "spawns drain the root pool from any level, and release re-admits" do
    check all {graph, meta} <- Gen.graph(), levels <- integer(0..4), max_runs: 30 do
      auth = Gen.rooted({graph, meta}, ceiling: %{max_concurrent_tasks: 3})

      # The ceiling only clamps downward: the pool is the root node's own
      # max_concurrent_tasks bounded by the ceiling, never raised to it.
      generated = graph["nodes"][meta.source]["limits"]["max_concurrent_tasks"]
      cap = min(generated, 3)
      assert Authority.budget(auth).cap == cap

      # Descend for free via synchronous calls…
      bottom =
        if levels == 0 do
          auth
        else
          Enum.reduce(1..levels, auth, fn i, acc ->
            need = Gen.compliant_need(acc, meta)

            {:child_zero, child} =
              Transition.step(acc, :call, Gen.invoke_at(acc, meta, "formula:evil.corp.l#{i}", need))

            child
          end)
        end

      # …then spawn at the bottom until the ROOT pool runs dry.
      successes =
        Enum.count(1..(cap + 2), fn i ->
          need = Gen.compliant_need(bottom, meta)

          match?(
            {:child_zero, _},
            Transition.step(
              bottom,
              :spawn,
              Gen.invoke_at(bottom, meta, "formula:evil.corp.s#{i}", need)
            )
          )
        end)

      assert successes == cap
      assert Authority.budget(auth) == %{in_flight: cap, cap: cap}

      # The pool is shared: the ROOT cannot spawn either.
      assert {:deny, :invoke_budget_exhausted} =
               Transition.step(
                 auth,
                 :spawn,
                 Gen.invoke_at(auth, meta, "formula:evil.corp.root-spawn", Gen.compliant_need(auth, meta))
               )

      # Releasing re-admits exactly as many as were released.
      Enum.each(1..cap, fn _ -> Authority.release_invoke(auth) end)
      assert Authority.budget(auth).in_flight == 0

      assert {:child_zero, _} =
               Transition.step(
                 bottom,
                 :spawn,
                 Gen.invoke_at(bottom, meta, "formula:evil.corp.again", Gen.compliant_need(bottom, meta))
               )
    end
  end
end
