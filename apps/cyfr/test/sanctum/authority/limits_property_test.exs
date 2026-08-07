# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.LimitsPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sanctum.Authority
  alias Sanctum.Authority.Transition
  alias Sanctum.Policy.Ceiling
  alias Sanctum.Test.AuthorityGen, as: Gen

  # §6 "Separate properties", arm 3 — limits: every bound execution runs
  # under its own node's ceiling-clamped limits (clamped once, at root
  # construction), and every unbound one under the zero literals.

  property "bound limits are the node's clamped limits; unbound are the zero literals" do
    check all(
            {graph, meta} <- Gen.graph(self_edges: false),
            steps <- Gen.walk(meta),
            max_runs: 50
          ) do
      auth = Gen.rooted({graph, meta})
      raw = Gen.blob!(graph)
      ceiling = Ceiling.platform_ceiling()

      for {_before, _step, _outcome, after_auth} <- Gen.run_walk(auth, meta, steps) do
        case Authority.current_node(after_auth) do
          {:ok, node} ->
            {:ok, raw_limits} = Sanctum.Authority.Blob.node_limits(raw, node)
            assert Authority.limits(after_auth) == Sanctum.Limits.clamp(raw_limits, ceiling)

          :unbound ->
            assert Authority.limits(after_auth) == Authority.zero_limits()
        end
      end
    end
  end

  property "a nested callee executes under its own limits, not its caller's" do
    check all({graph, meta} <- Gen.graph(self_edges: false), max_runs: 30) do
      auth = Gen.rooted({graph, meta})
      {:ok, source} = Authority.current_node(auth)

      for {to, need} <- Gen.reachable_edges(meta, source) do
        need_arg = if need == "", do: nil, else: need
        {:child, child} = Transition.step(auth, :call, Gen.invoke_at(auth, meta, to, need_arg))

        {:ok, callee_limits} = Sanctum.Authority.Blob.node_limits(auth.policy, to)
        assert Authority.limits(child) == callee_limits
      end
    end
  end
end
