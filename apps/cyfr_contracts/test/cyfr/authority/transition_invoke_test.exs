# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Cyfr.Authority.TransitionInvokeTest do
  use ExUnit.Case, async: true

  alias Cyfr.Authority
  alias Cyfr.Authority.Transition
  alias Cyfr.Test.AuthorityFixtures, as: Fixtures

  @formula "formula:local.daily-report"
  @catalyst "catalyst:supabase.com.database"
  @reagent "reagent:local.ta"

  # ============================================================================
  # Edge dispatch
  # ============================================================================

  describe "edge dispatch" do
    test "a consented need binds the child with exactly that edge's resources" do
      auth = Fixtures.root!()

      {:child, child} =
        Transition.step(
          auth,
          :call,
          Fixtures.invoke(@catalyst, need: "source", declared_needs: Fixtures.formula_needs())
        )

      assert child.cursor == {:bound, @catalyst}
      assert child.resources.vault.entry_id == "vault-source"
      assert child.resources.vault.projection.fields == ["url", "anon_key"]
      assert child.resources.egress.domains == ["prod.supabase.co"]
      assert child.chain == [@formula, @catalyst]
      assert child.depth == 1
      # The child executes under the CALLEE's own limits.
      assert Authority.limits(child).timeout == "30s"
    end

    test "two needs on one ref resolve to different credentials" do
      auth = Fixtures.root!()
      needs = Fixtures.formula_needs()

      {:child, source} =
        Transition.step(
          auth,
          :call,
          Fixtures.invoke(@catalyst, need: "source", declared_needs: needs)
        )

      {:child, dest} =
        Transition.step(
          auth,
          :call,
          Fixtures.invoke(@catalyst, need: "dest", declared_needs: needs)
        )

      assert source.resources.vault.entry_id == "vault-source"
      assert dest.resources.vault.entry_id == "vault-dest"
      assert dest.resources.egress == nil
    end

    test "the unnamed slot works when no needs are declared" do
      auth = Fixtures.root!()

      {:child, child} = Transition.step(auth, :call, Fixtures.invoke(@reagent))

      assert child.cursor == {:bound, @reagent}
      # An invocation-only edge: authorized to run, carrying nothing.
      assert child.resources.vault == nil
      assert child.resources.tools == []
    end

    test "an unconsented target drops to a zero child under :open_inert" do
      auth = Fixtures.root!()

      {:child_zero, child} =
        Transition.step(auth, :call, Fixtures.invoke("formula:evil.corp.helper"))

      assert child.cursor == :unbound
      assert child.policy == :none
      assert child.resources == :none
      assert child.chain == [@formula, "formula:evil.corp.helper"]
      assert Authority.limits(child) == Authority.zero_limits()
    end

    test "an :edge_only profile denies edge-miss invokes instead of going inert" do
      auth = Fixtures.root!(%{kind: :public, invoke_mode: :edge_only})

      assert {:deny, :edge_only} =
               Transition.step(auth, :call, Fixtures.invoke("formula:evil.corp.helper"))

      # Consented edges still work.
      assert {:child, _} =
               Transition.step(
                 auth,
                 :call,
                 Fixtures.invoke(@catalyst,
                   need: "source",
                   declared_needs: Fixtures.formula_needs()
                 )
               )
    end
  end

  # Need rules

  describe "need rules" do
    test "omission is rejected when named needs are declared" do
      auth = Fixtures.root!()
      needs = Fixtures.formula_needs()

      assert {:deny, {:need, :required}} =
               Transition.step(auth, :call, Fixtures.invoke(@catalyst, declared_needs: needs))

      assert {:deny, {:need, :required}} =
               Transition.step(
                 auth,
                 :call,
                 Fixtures.invoke(@catalyst, need: "", declared_needs: needs)
               )
    end

    test "an undeclared need is rejected, not coerced" do
      auth = Fixtures.root!()

      assert {:deny, {:need, :undeclared}} =
               Transition.step(
                 auth,
                 :call,
                 Fixtures.invoke(@catalyst,
                   need: "backup",
                   declared_needs: Fixtures.formula_needs()
                 )
               )

      # A need is undeclared even when the manifest declares none.
      assert {:deny, {:need, :undeclared}} =
               Transition.step(auth, :call, Fixtures.invoke(@catalyst, need: "source"))
    end
  end

  # Self-invocation

  describe "self-invocation" do
    test "the same activation identity preserves cursor and resources" do
      auth = Fixtures.root!()
      self_digest = Fixtures.activation()[@formula]

      # Self-invocation permits omitted needs even when the manifest declares them.
      {:child, child} =
        Transition.step(
          auth,
          :call,
          Fixtures.invoke(@formula,
            activation_digest: self_digest,
            declared_needs: Fixtures.formula_needs()
          )
        )

      assert child.cursor == auth.cursor
      assert child.resources == auth.resources
      assert child.policy == auth.policy
      assert child.chain == [@formula, @formula]
      assert child.depth == 1
    end

    test "the same ref at a different activation gets no inheritance" do
      auth = Fixtures.root!()

      # After an upgrade the self-reference resolves to a new digest: a
      # different node — no silent inheritance, ordinary dispatch instead.
      outcome =
        Transition.step(
          auth,
          :call,
          Fixtures.invoke(@formula, activation_digest: "sha256:upgraded")
        )

      # No F→F edge exists, so ordinary dispatch goes inert.
      assert {:child_zero, child} = outcome
      assert child.cursor == :unbound
    end

    test "a missing activation digest never self-matches" do
      auth = Fixtures.root!()

      assert {:child_zero, _} = Transition.step(auth, :call, Fixtures.invoke(@formula))
    end
  end

  # ============================================================================
  # Depth
  # ============================================================================

  describe "depth cap" do
    test "the chain denies at exactly the cap" do
      auth = Fixtures.root!()
      cap = Authority.depth_cap()

      final =
        Enum.reduce(1..cap, auth, fn i, acc ->
          {:child_zero, child} =
            Transition.step(acc, :call, Fixtures.invoke("formula:local.step#{i}"))

          child
        end)

      assert final.depth == cap

      assert {:deny, :depth_cap} =
               Transition.step(final, :call, Fixtures.invoke("formula:local.overflow"))

      # Depth also bounds self-invocation and spawn.
      deep_bound = Enum.reduce(1..cap, auth, fn _, acc -> Authority.self_child(acc, @formula) end)

      assert {:deny, :depth_cap} =
               Transition.step(
                 deep_bound,
                 :spawn,
                 Fixtures.invoke(@formula, activation_digest: Fixtures.activation()[@formula])
               )
    end
  end
end
