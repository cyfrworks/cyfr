# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.CommitDigestTest do
  use ExUnit.Case, async: true

  alias Sanctum.Consent.CommitDigest

  doctest Sanctum.Consent.CommitDigest

  @base %{shape_digest: "sha256:shape", kind: :owner, invoke_mode: :open_inert}

  @binding %{
    need: "source",
    entry_id: "vault-1",
    binding_digest: "sha256:bind-1",
    fields: ["url", "anon_key"]
  }

  defp digest!(commit) do
    {:ok, digest} = CommitDigest.compute(commit)
    digest
  end

  describe "compute/1" do
    test "every decision changes the digest" do
      variants = [
        %{shape_digest: "sha256:other-shape"},
        %{kind: :public, invoke_mode: :edge_only},
        %{invoke_mode: :edge_only},
        %{bindings: [@binding]},
        %{slot_bindings: %{"source" => "vault-1"}},
        %{override: true},
        %{limits: %{"timeout" => "30s"}}
      ]

      for variant <- variants do
        assert digest!(@base) != digest!(Map.merge(@base, variant)),
               "#{inspect(variant)} did not affect the digest"
      end
    end

    test "binding order does not change the digest" do
      second = %{@binding | need: "dest", entry_id: "vault-2", binding_digest: "sha256:bind-2"}

      assert digest!(Map.put(@base, :bindings, [@binding, second])) ==
               digest!(Map.put(@base, :bindings, [second, @binding]))
    end
  end

  # ============================================================================
  # The decisions a proof must cover
  # ============================================================================

  describe "vault bindings" do
    test "a rebinding changes the digest even at the same entry" do
      # Same credential row, repointed at a different account: the entry id
      # alone would let the new binding inherit the old consent.
      rebound = %{@binding | binding_digest: "sha256:bind-rebound"}

      assert digest!(Map.put(@base, :bindings, [@binding])) !=
               digest!(Map.put(@base, :bindings, [rebound]))
    end

    test "a widened projection changes the digest" do
      widened = %{@binding | fields: ["url", "anon_key", "service_key"]}

      assert digest!(Map.put(@base, :bindings, [@binding])) !=
               digest!(Map.put(@base, :bindings, [widened]))
    end

    test "a need may be bound exactly once" do
      duplicate = %{@binding | entry_id: "vault-2", binding_digest: "sha256:bind-2"}

      assert {:error, {:invalid_commit, :bindings, message}} =
               CommitDigest.compute(Map.put(@base, :bindings, [@binding, duplicate]))

      assert message =~ "exactly once"
    end

    test "bindings require an entry id and a binding digest" do
      assert {:error, {:invalid_commit, :entry_id, _}} =
               CommitDigest.compute(Map.put(@base, :bindings, [Map.delete(@binding, :entry_id)]))

      assert {:error, {:invalid_commit, :binding_digest, _}} =
               CommitDigest.compute(
                 Map.put(@base, :bindings, [Map.delete(@binding, :binding_digest)])
               )
    end
  end

  describe "containment invariants" do
    test "a public profile that could invoke freely has no representable digest" do
      assert {:error, {:invalid_commit, :invoke_mode, message}} =
               CommitDigest.compute(%{@base | kind: :public})

      assert message =~ "edge_only"

      assert {:ok, _} =
               CommitDigest.compute(%{@base | kind: :public, invoke_mode: :edge_only})
    end
  end

  describe "input validation" do
    test "rejects unknown fields and malformed values" do
      assert {:error, {:invalid_commit, :unknown_field, _}} =
               CommitDigest.compute(Map.put(@base, :extra, 1))

      assert {:error, {:invalid_commit, :shape_digest, _}} =
               CommitDigest.compute(Map.delete(@base, :shape_digest))

      assert {:error, {:invalid_commit, :kind, _}} =
               CommitDigest.compute(%{@base | kind: :admin})

      assert {:error, {:invalid_commit, :override, _}} =
               CommitDigest.compute(Map.put(@base, :override, "yes"))

      assert {:error, {:invalid_commit, :slot_bindings, _}} =
               CommitDigest.compute(Map.put(@base, :slot_bindings, %{"source" => nil}))
    end

    test "rejects loose durations and floats in resolved limits" do
      assert {:error, {:invalid_commit, :caps, _}} =
               CommitDigest.compute(Map.put(@base, :limits, %{"timeout" => "5mm"}))

      assert {:error, {:invalid_commit, :caps, _}} =
               CommitDigest.compute(Map.put(@base, :limits, %{"max_memory_bytes" => 1.5}))
    end
  end

  describe "normalize/1" do
    test "embeds the shape digest as a string rather than re-expanding it" do
      {:ok, canonical} = CommitDigest.normalize(Map.put(@base, :bindings, [@binding]))

      assert canonical["shape_digest"] == "sha256:shape"
      assert [%{"need" => "source", "fields" => ["anon_key", "url"]}] = canonical["bindings"]
      assert canonical["override"] == false
    end
  end
end
