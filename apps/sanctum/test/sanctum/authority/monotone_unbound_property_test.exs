# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.MonotoneUnboundPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Prima.Authority
  alias Prima.Authority.Transition
  alias Sanctum.Test.AuthorityGen, as: Gen

  # Once unbound, every subsequent transition stays unbound and uses zero-authority limits.

  property "unboundness is absorbing along any walk" do
    check all(
            {graph, meta} <- Gen.graph(),
            steps <- Gen.walk(meta),
            max_runs: 50
          ) do
      auth = Gen.rooted({graph, meta})
      trace = Gen.run_walk(auth, meta, steps)

      Enum.reduce(trace, false, fn {before, _step, outcome, after_auth}, went_unbound? ->
        if went_unbound? do
          refute Authority.bound?(before)
          assert before.policy == :none
          assert before.resources == :none
          assert Authority.limits(before) == Authority.zero_limits()
          refute match?({:child, _}, outcome)

          # The control plane stays closed too.
          assert {:deny, :unbound_control_plane} =
                   Transition.step(before, :call, {:tool, %{tool: "storage", action: "read"}})
        end

        went_unbound? or not Authority.bound?(after_auth)
      end)
    end
  end

  property "a zero child's identity fields are gone, not merely ignored" do
    check all({graph, meta} <- Gen.graph(), max_runs: 50) do
      auth = Gen.rooted({graph, meta})
      need = Gen.compliant_need(auth, meta)

      {:child_zero, child} =
        Transition.step(auth, :call, Gen.invoke_at(auth, meta, "formula:evil.corp.helper", need))

      assert child.profile_id == nil
      assert child.consent_id == nil
      assert child.source_ref == nil
      assert child.profile_kind == nil
      assert child.activation == %{}
      assert child.policy == :none
      assert child.resources == :none
    end
  end
end
