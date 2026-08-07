# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.InvocationPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sanctum.Authority
  alias Sanctum.Authority.Transition
  alias Sanctum.Test.AuthorityGen, as: Gen

  # §6 "Separate properties", arm 1 — invocation authority alone: which
  # targets may be invoked at all, decided by edge presence and
  # invoke_mode, independent of what any edge carries.

  property "edge presence and invoke_mode fully decide invocability" do
    check all {graph, meta} <- Gen.graph(self_edges: false), max_runs: 50 do
      open = Gen.rooted({graph, meta})
      {:ok, source} = Authority.current_node(open)
      edges = Gen.reachable_edges(meta, source)

      # Every reachable consented edge is invocable.
      for {to, need} <- edges do
        need_arg = if need == "", do: nil, else: need

        assert {:child, _} =
                 Transition.step(open, :call, Gen.invoke_at(open, meta, to, need_arg)),
               "consented edge #{source} -> #{to} (#{inspect(need)}) was not invocable"
      end

      # A §2.7 consequence, pinned: once a manifest declares needs, its
      # unnamed edges are dead — omission is rejected outright.
      for {to, ""} <- Gen.unreachable_edges(meta, source) do
        assert {:deny, {:need, :required}} =
                 Transition.step(open, :call, Gen.invoke_at(open, meta, to, nil))
      end

      # Off-graph dynamic dispatch stays possible under :open_inert…
      off_need = Gen.compliant_need(open, meta)

      assert {:child_zero, _} =
               Transition.step(
                 open,
                 :call,
                 Gen.invoke_at(open, meta, "formula:evil.corp.dynamic", off_need)
               )

      # …and is refused under :edge_only, while consented edges still work.
      edge_only = Gen.rooted({graph, meta}, kind: :public, invoke_mode: :edge_only)

      assert {:deny, :edge_only} =
               Transition.step(
                 edge_only,
                 :call,
                 Gen.invoke_at(edge_only, meta, "formula:evil.corp.dynamic", off_need)
               )

      for {to, need} <- Gen.reachable_edges(meta, source) do
        need_arg = if need == "", do: nil, else: need

        assert {:child, _} =
                 Transition.step(edge_only, :call, Gen.invoke_at(edge_only, meta, to, need_arg))
      end
    end
  end
end
