# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.NeedDispatchPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Prima.Authority.Transition
  alias Sanctum.Test.AuthorityGen, as: Gen

  # Reject undeclared or ambiguous needs and omissions when needs are declared; match each need to its edge.

  property "need dispatch rules hold on any generated graph" do
    check all({graph, meta} <- Gen.graph(self_edges: false), max_runs: 50) do
      auth = Gen.rooted({graph, meta})
      {:ok, source} = Authority.current_node(auth)
      declared = Map.get(meta.declared_needs, source, [])
      targets = Gen.outgoing(meta)[source] || []
      # Use a non-self target so need validation is exercised.
      any_target = Enum.find(meta.nodes, &(&1 != source))

      if declared == [] do
        # No named needs: the unnamed slot is the ordinary case.
        for {to, ""} <- targets do
          {:child, child} =
            Transition.step(auth, :call, Gen.invoke_at(auth, meta, to, nil))

          {:ok, edge} = Blob.lookup_edge(auth.policy, source, to, "")
          assert child.resources == edge
        end

        # But a need out of thin air is undeclared.
        assert {:deny, {:need, :undeclared}} =
                 Transition.step(auth, :call, Gen.invoke_at(auth, meta, any_target, "source"))
      else
        # Omission is rejected outright…
        assert {:deny, {:need, :required}} =
                 Transition.step(auth, :call, Gen.invoke_at(auth, meta, any_target, nil))

        # …as is any need the manifest does not declare.
        undeclared = "zz-not-declared"

        assert {:deny, {:need, :undeclared}} =
                 Transition.step(
                   auth,
                   :call,
                   Gen.invoke_at(auth, meta, any_target, undeclared)
                 )

        # Every declared need dispatches to exactly its own edge.
        for {to, need} <- targets, need != "" do
          {:child, child} = Transition.step(auth, :call, Gen.invoke_at(auth, meta, to, need))
          {:ok, edge} = Blob.lookup_edge(auth.policy, source, to, need)
          assert child.resources == edge
        end
      end
    end
  end
end
