# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.CommitDigestTest do
  use ExUnit.Case, async: true

  alias Sanctum.Consent.CommitDigest

  doctest Sanctum.Consent.CommitDigest

  @base %{
    shape_digest: "sha256:shape",
    blob_digest: "sha256:blob",
    label: "default",
    kind: :owner,
    invoke_mode: :open_inert
  }

  @binding %{
    need: "source",
    entry_id: "vault-1",
    binding_digest: "sha256:bind-1",
    fields: ["url", "anon_key"]
  }

  @selection %{
    from: "reagent:local.src",
    dep: "catalyst:local.claude",
    label: "default",
    binding_digest: "sha256:sel-1"
  }

  defp digest!(commit) do
    {:ok, digest} = CommitDigest.compute(commit)
    digest
  end

  describe "compute/1" do
    test "every decision changes the digest" do
      variants = [
        %{shape_digest: "sha256:other-shape"},
        # The blob hash is the field that makes this list closed: any
        # decision that reaches the resolved policy moves it, whether or
        # not it is also spelled out above.
        %{blob_digest: "sha256:other-blob"},
        %{kind: :public, invoke_mode: :edge_only},
        %{invoke_mode: :edge_only},
        %{bindings: [@binding]},
        # Which profile the grant lands on. Two owner profiles on one
        # source_ref under different labels can produce byte-identical
        # blobs, and on a first consent the proof binds no profile_id and
        # revision 0 for either — so without this a proof minted for one
        # label was spendable on the other.
        %{label: "staging"},
        %{override: true}
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

      # Required, not optional. A digest computed without the blob hash is
      # the shape `durable_storage` escaped through: approved under one
      # policy, committed under another.
      assert {:error, {:invalid_commit, :blob_digest, _}} =
               CommitDigest.compute(Map.delete(@base, :blob_digest))

      assert {:error, {:invalid_commit, :kind, _}} =
               CommitDigest.compute(%{@base | kind: :admin})

      assert {:error, {:invalid_commit, :override, _}} =
               CommitDigest.compute(Map.put(@base, :override, "yes"))

      assert {:error, {:invalid_commit, :label, _}} =
               CommitDigest.compute(Map.delete(@base, :label))
    end

    # The resolved blob hash covers slot bindings and node limits.
    test "keys no producer supplies are refused rather than silently accepted" do
      assert {:error, {:invalid_commit, :unknown_field, ":slot_bindings"}} =
               CommitDigest.compute(Map.put(@base, :slot_bindings, %{"source" => "vault-1"}))

      assert {:error, {:invalid_commit, :unknown_field, ":limits"}} =
               CommitDigest.compute(Map.put(@base, :limits, %{"timeout" => "30s"}))
    end
  end

  describe "selections" do
    test "from is part of the digest" do
      other = %{@selection | from: "reagent:local.other"}

      assert digest!(Map.put(@base, :selections, [@selection])) !=
               digest!(Map.put(@base, :selections, [other]))
    end

    test "the same dep may be selected once per from" do
      second = %{@selection | from: "reagent:local.other"}

      assert {:ok, _} =
               CommitDigest.compute(Map.put(@base, :selections, [@selection, second]))

      dup = %{@selection | label: "work"}

      assert {:error, {:invalid_commit, :selections, message}} =
               CommitDigest.compute(Map.put(@base, :selections, [@selection, dup]))

      assert message =~ "exactly once"
    end

    test "from is required" do
      assert {:error, {:invalid_commit, :from, _}} =
               CommitDigest.compute(Map.put(@base, :selections, [Map.delete(@selection, :from)]))
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
