# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.SelfInvocationPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sanctum.Authority
  alias Sanctum.Authority.Transition
  alias Sanctum.Test.AuthorityGen, as: Gen

  # §6 "Self-invocation (D2)": a sub-agent at the same activation identity
  # keeps cursor and resources; the same ref at a *different* activation
  # does not. Graphs are generated without self-edges so the wrong-digest
  # case cannot be satisfied by a real edge and the distinction is sharp.

  property "same activation inherits; same ref at a different activation does not" do
    check all {graph, meta} <- Gen.graph(self_edges: false), max_runs: 50 do
      auth = Gen.rooted({graph, meta})
      {:ok, node} = Authority.current_node(auth)
      declared = Map.get(meta.declared_needs, node, [])

      same =
        {:invoke,
         %{
           reference: node,
           need: nil,
           activation_digest: meta.activation[node],
           declared_needs: declared
         }}

      # D2 bypasses the need rules even when needs are declared — the
      # sub-agent case.
      {:child, child} = Transition.step(auth, :call, same)
      assert child.cursor == auth.cursor
      assert child.resources == auth.resources
      assert child.policy == auth.policy
      assert child.depth == auth.depth + 1
      assert List.last(child.chain) == node

      # After an "upgrade", the self-reference resolves to a new digest:
      # ordinary dispatch, no inheritance.
      upgraded = %{
        reference: node,
        need: nil,
        activation_digest: "sha256:upgraded-elsewhere",
        declared_needs: declared
      }

      case Transition.step(auth, :call, {:invoke, upgraded}) do
        {:child_zero, zero_child} ->
          assert zero_child.cursor == :unbound
          assert zero_child.resources == :none

        {:deny, {:need, :required}} ->
          # Declared needs + omitted need: ordinary dispatch rules apply,
          # which is exactly the point — D2 did not short-circuit them.
          assert declared != []

        other ->
          flunk("unexpected outcome for different-activation self-invoke: #{inspect(other)}")
      end
    end
  end

  property "a nil activation digest never inherits" do
    check all {graph, meta} <- Gen.graph(self_edges: false), max_runs: 30 do
      auth = Gen.rooted({graph, meta})
      {:ok, node} = Authority.current_node(auth)

      outcome =
        Transition.step(
          auth,
          :call,
          {:invoke, %{reference: node, need: nil, activation_digest: nil, declared_needs: []}}
        )

      assert {:child_zero, _} = outcome
    end
  end
end
