# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.ProofTest do
  # The model §6 "Proof binds commit" gate: a proof minted for one commit
  # digest is rejected for another, and replay and expiry are rejected.
  use ExUnit.Case, async: false

  alias Sanctum.Consent.Proof

  @bindings %{
    kind: :consent_commit,
    commit_digest: "sha256:commit-one",
    actor: "user_1",
    athanor_id: "ath_test",
    profile_id: "prof-1",
    expected_revision: 2
  }

  describe "mint and consume" do
    test "a proof authorizes exactly its bindings" do
      {:ok, token} = Proof.mint(@bindings)
      assert Proof.consume(token, @bindings) == :ok
    end

    test "a proof is single-use" do
      {:ok, token} = Proof.mint(@bindings)

      assert Proof.consume(token, @bindings) == :ok
      assert Proof.consume(token, @bindings) == {:error, :not_found}
    end

    test "an unknown token is refused" do
      assert Proof.consume("not-a-token", @bindings) == {:error, :not_found}
    end

    test "each mint is independent" do
      {:ok, first} = Proof.mint(@bindings)
      {:ok, second} = Proof.mint(@bindings)

      refute first == second
      assert Proof.consume(first, @bindings) == :ok
      assert Proof.consume(second, @bindings) == :ok
    end
  end

  # ============================================================================
  # Binding
  # ============================================================================

  describe "binding" do
    test "a proof minted for one commit digest is rejected for another" do
      {:ok, token} = Proof.mint(@bindings)

      assert Proof.consume(token, %{@bindings | commit_digest: "sha256:commit-two"}) ==
               {:error, {:binding_mismatch, :commit_digest}}
    end

    test "every binding field is load-bearing" do
      for {field, changed} <- [
            actor: "user_2",
            athanor_id: "ath_other",
            profile_id: "prof-2",
            expected_revision: 3,
            kind: :something_else
          ] do
        {:ok, token} = Proof.mint(@bindings)

        assert Proof.consume(token, Map.put(@bindings, field, changed)) ==
                 {:error, {:binding_mismatch, field}},
               "#{field} was not bound"
      end
    end

    test "a mismatched attempt consumes the token" do
      # A proof must not become an oracle for probing which decision
      # changed — one attempt, whatever the outcome.
      {:ok, token} = Proof.mint(@bindings)

      assert {:error, {:binding_mismatch, _}} =
               Proof.consume(token, %{@bindings | commit_digest: "sha256:wrong"})

      assert Proof.consume(token, @bindings) == {:error, :not_found}
    end

    test "an added or dropped binding is a mismatch, not a pass" do
      {:ok, token} = Proof.mint(@bindings)

      assert {:error, {:binding_mismatch, :extra}} =
               Proof.consume(token, Map.put(@bindings, :extra, "smuggled"))

      {:ok, token} = Proof.mint(@bindings)

      assert {:error, {:binding_mismatch, :profile_id}} =
               Proof.consume(token, Map.delete(@bindings, :profile_id))
    end
  end

  # ============================================================================
  # Expiry
  # ============================================================================

  describe "expiry" do
    test "an expired proof is refused" do
      {:ok, token} = Proof.mint(@bindings, ttl_ms: 1)
      Process.sleep(15)

      assert Proof.consume(token, @bindings) == {:error, :expired}
      # And it is gone, not merely refused.
      assert Proof.consume(token, @bindings) == {:error, :not_found}
    end

    test "the default lifetime is short" do
      assert Proof.default_ttl_ms() <= 300_000
    end

    test "the sweeper clears expired rows" do
      before = Proof.Memory.outstanding()
      {:ok, _} = Proof.mint(@bindings, ttl_ms: 1)

      Process.sleep(15)
      send(Process.whereis(Proof.Memory), :sweep)
      # Round-trip a call so the sweep has been processed.
      _ = Proof.Memory.outstanding()

      assert Proof.Memory.outstanding() == before
    end
  end

  # ============================================================================
  # Input validation
  # ============================================================================

  describe "validation" do
    test "bindings must carry a kind, a commit digest and an athanor" do
      assert {:error, {:invalid_bindings, :commit_digest}} =
               Proof.mint(Map.delete(@bindings, :commit_digest))

      assert {:error, {:invalid_bindings, :kind}} = Proof.mint(Map.delete(@bindings, :kind))

      assert {:error, {:invalid_bindings, :commit_digest}} =
               Proof.mint(%{@bindings | commit_digest: ""})

      # A proof is minted inside one athanor; a binding that names none
      # could be consumed from anywhere.
      assert {:error, {:invalid_bindings, :athanor_id}} =
               Proof.mint(Map.delete(@bindings, :athanor_id))

      assert {:error, {:invalid_bindings, :athanor_id}} =
               Proof.mint(%{@bindings | athanor_id: ""})

      assert {:error, {:invalid_bindings, :bindings}} = Proof.mint("nope")
    end

    test "a non-string token is refused without touching the store" do
      assert Proof.consume(nil, @bindings) == {:error, {:invalid_bindings, :token}}
    end
  end
end
