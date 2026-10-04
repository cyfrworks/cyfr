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
    invoke_mode: :open_inert,
    origins: [:interactive]
  }

  @node "reagent:local.weather"

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
        %{override: true},
        # What the grant admits, and how the ask was narrowed.
        %{origins: [:interactive, :programmatic]},
        %{subset: %{@node => %{"egress" => %{"domains" => ["api.weather.example"]}}}}
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

    test "bindings require exactly one entry and a binding digest" do
      assert {:error, {:invalid_commit, :bindings, why}} =
               CommitDigest.compute(Map.put(@base, :bindings, [Map.delete(@binding, :entry_id)]))

      assert why =~ "exactly one of entry_id, instance_entry_id"

      both = Map.put(@binding, :instance_entry_id, "ine-1")

      assert {:error, {:invalid_commit, :bindings, _}} =
               CommitDigest.compute(Map.put(@base, :bindings, [both]))

      assert {:error, {:invalid_commit, :binding_digest, _}} =
               CommitDigest.compute(
                 Map.put(@base, :bindings, [Map.delete(@binding, :binding_digest)])
               )
    end
  end

  describe "accounts, instance entries and lifetimes" do
    @standing %{kind: "standing"}
    @until %{kind: "until", until: "2026-10-04T12:00:00Z"}

    test "the instance id, the account name, the lifetime and renew each change the digest" do
      base = Map.put(@base, :bindings, [Map.put(@binding, :lifetime, @standing)])

      variants = [
        [@binding |> Map.delete(:entry_id) |> Map.put(:instance_entry_id, "vault-1")],
        [Map.put(@binding, :name, "Supabase 1")],
        [Map.put(@binding, :lifetime, %{kind: "once"})],
        [Map.put(@binding, :lifetime, @until)],
        [Map.put(@binding, :lifetime, %{@until | until: "2026-10-04T12:05:00Z"})],
        [Map.put(@binding, :renew, true)]
      ]

      for bindings <- variants do
        assert digest!(base) != digest!(Map.put(@base, :bindings, bindings)),
               "#{inspect(bindings)} did not affect the digest"
      end

      # An absent lifetime is a standing one, and an absent renew is false.
      assert digest!(base) == digest!(Map.put(@base, :bindings, [@binding]))

      assert digest!(base) ==
               digest!(Map.put(@base, :bindings, [Map.put(@binding, :renew, false)]))
    end

    test "a need binds its default and each named account once" do
      named = %{@binding | entry_id: "vault-2", binding_digest: "sha256:bind-2"}

      assert {:ok, _} =
               CommitDigest.compute(
                 Map.put(@base, :bindings, [@binding, Map.put(named, :name, "Supabase 2")])
               )

      assert {:error, {:invalid_commit, :bindings, _}} =
               CommitDigest.compute(
                 Map.put(@base, :bindings, [
                   Map.put(@binding, :name, "Supabase 2"),
                   Map.put(named, :name, "Supabase 2")
                 ])
               )
    end

    test "a lifetime is standing, until an instant or once, and only until names one" do
      for lifetime <- [
            %{kind: "forever"},
            %{kind: "until"},
            %{kind: "once", until: "2026-10-04T12:00:00Z"},
            "standing"
          ] do
        assert {:error, {:invalid_commit, :lifetime, _}} =
                 CommitDigest.compute(
                   Map.put(@base, :bindings, [Map.put(@binding, :lifetime, lifetime)])
                 ),
               "#{inspect(lifetime)} was accepted"
      end

      assert {:error, {:invalid_commit, :renew, _}} =
               CommitDigest.compute(Map.put(@base, :bindings, [Map.put(@binding, :renew, "yes")]))
    end

    test "a selection's entry, need, lifetime and renew each change the digest" do
      entry =
        @selection |> Map.delete(:label) |> Map.merge(%{entry_id: "vault-1", need: "api_key"})

      base = Map.put(@base, :selections, [entry])

      variants = [
        [@selection],
        [entry |> Map.delete(:entry_id) |> Map.put(:instance_entry_id, "vault-1")],
        [%{entry | need: "other"}],
        [Map.put(entry, :lifetime, %{kind: "once"})],
        [Map.put(entry, :renew, true)],
        [Map.put(@selection, :lifetime, @until)]
      ]

      for selections <- variants do
        assert digest!(base) != digest!(Map.put(@base, :selections, selections)),
               "#{inspect(selections)} did not affect the digest"
      end

      # A selection names exactly one of a label, an entry and an
      # instance entry.
      assert {:error, {:invalid_commit, :selections, _}} =
               CommitDigest.compute(
                 Map.put(@base, :selections, [Map.put(@selection, :entry_id, "vault-1")])
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

  describe "origins" do
    test "are required: a digest that binds no origins cannot be computed" do
      assert {:error, {:invalid_commit, :origins, "is required"}} =
               CommitDigest.compute(Map.delete(@base, :origins))
    end

    test "an empty list, an unknown origin, a spelling and a duplicate are refused" do
      for origins <- [[], [:cli], ["interactive"], [:interactive, :interactive], :interactive] do
        assert {:error, {:invalid_commit, :origins, _why}} =
                 CommitDigest.compute(%{@base | origins: origins}),
               "#{inspect(origins)} was accepted"
      end
    end

    test "are a set: order does not change the digest, and they bind as wire spellings" do
      assert digest!(%{@base | origins: [:webhook, :interactive]}) ==
               digest!(%{@base | origins: [:interactive, :webhook]})

      {:ok, canonical} = CommitDigest.normalize(%{@base | origins: [:schedule, :interactive]})
      assert canonical["origins"] == ["interactive", "schedule"]
    end

    test "each origin changes the digest" do
      digests =
        for origin <- Prima.Origin.values(),
            do: digest!(%{@base | origins: [origin]})

      assert length(Enum.uniq(digests)) == length(Prima.Origin.values())
    end
  end

  describe "subset" do
    @narrowing %{
      @node => %{
        "egress" => %{"domains" => ["b.example", "a.example", "a.example"]},
        "storage" => %{"paths" => ["data/notes/"]},
        "tools" => ["file.read"],
        "limits" => %{"timeout" => "30s", "rate_limit" => %{"requests" => 10}}
      }
    }

    test "normalizes to sorted, deduplicated sets and drops records that name nothing" do
      {:ok, canonical} =
        CommitDigest.normalize(
          Map.put(
            @base,
            :subset,
            Map.merge(@narrowing, %{"reagent:local.other" => %{"egress" => %{}}})
          )
        )

      assert canonical["subset"] == %{
               @node => %{
                 "egress" => %{"domains" => ["a.example", "b.example"]},
                 "storage" => %{"paths" => ["data/notes/"]},
                 "tools" => ["file.read"],
                 "limits" => %{"timeout" => "30s", "rate_limit" => %{"requests" => 10}}
               }
             }

      assert digest!(Map.put(@base, :subset, %{@node => %{"egress" => %{}}})) == digest!(@base)
    end

    test "a field left out and a field named empty are different decisions" do
      left_out = %{@node => %{"egress" => %{"methods" => ["GET"]}}}
      empty = %{@node => %{"egress" => %{"methods" => ["GET"], "domains" => []}}}

      assert digest!(Map.put(@base, :subset, left_out)) !=
               digest!(Map.put(@base, :subset, empty))
    end

    test "set order does not change the digest; a value does" do
      one = %{@node => %{"storage" => %{"actions" => ["read", "list"]}}}
      other = %{@node => %{"storage" => %{"actions" => ["list", "read"]}}}
      narrower = %{@node => %{"storage" => %{"actions" => ["read"]}}}

      assert digest!(Map.put(@base, :subset, one)) == digest!(Map.put(@base, :subset, other))
      assert digest!(Map.put(@base, :subset, one)) != digest!(Map.put(@base, :subset, narrower))
    end

    test "a kind its enforcement point cannot narrow is refused, never bound as narrowed" do
      for kind <- ~w(credential tool_servers frame streams cards system_actions) do
        assert {:error, {:invalid_commit, :subset, why}} =
                 CommitDigest.compute(Map.put(@base, :subset, %{@node => %{kind => %{}}}))

        assert why =~ "#{kind} cannot be narrowed"
      end

      assert {:error, {:invalid_commit, :subset, why}} =
               CommitDigest.compute(Map.put(@base, :subset, %{@node => %{"ports" => []}}))

      assert why =~ "not one of egress, storage, tools, limits"
    end

    test "malformed narrowings are refused" do
      for {subset, fragment} <- [
            {%{"reagent:local.x:1.0.0" => %{}}, "name-level"},
            {%{"not a ref" => %{}}, "name-level"},
            {%{@node => []}, "record"},
            {%{@node => %{"egress" => %{"ports" => ["443"]}}}, "egress narrows only"},
            {%{@node => %{"egress" => %{"domains" => "a.example"}}}, "egress.domains"},
            {%{@node => %{"storage" => %{"paths" => [""]}}}, "storage.paths"},
            {%{@node => %{"tools" => ["file.*"]}}, "tool.action"},
            {%{@node => %{"limits" => %{"timeout" => "5mm"}}}, "exact duration"},
            {%{@node => %{"limits" => %{"max_memory_bytes" => -1}}}, "non-negative"},
            {%{@node => %{"limits" => %{"rate_limit" => %{"burst" => 1}}}},
             "requests and window"},
            {%{@node => %{"limits" => %{"ports" => 1}}}, "is not a limit"}
          ] do
        assert {:error, {:invalid_commit, _key, why}} =
                 CommitDigest.compute(Map.put(@base, :subset, subset)),
               "#{inspect(subset)} was accepted"

        assert why =~ fragment, "#{inspect(subset)}: #{why}"
      end

      assert {:error, {:invalid_commit, :subset, _}} =
               CommitDigest.compute(Map.put(@base, :subset, ["not", "a", "map"]))
    end
  end

  describe "normalize/1" do
    test "embeds the shape digest as a string rather than re-expanding it" do
      {:ok, canonical} = CommitDigest.normalize(Map.put(@base, :bindings, [@binding]))

      assert canonical["shape_digest"] == "sha256:shape"

      assert [
               %{
                 "need" => "source",
                 "entry_id" => "vault-1",
                 "fields" => ["anon_key", "url"],
                 "lifetime" => %{"kind" => "standing"},
                 "renew" => false
               } = binding
             ] = canonical["bindings"]

      refute Map.has_key?(binding, "name")
      assert canonical["override"] == false
      assert canonical["origins"] == ["interactive"]
      assert canonical["subset"] == %{}
    end
  end
end
