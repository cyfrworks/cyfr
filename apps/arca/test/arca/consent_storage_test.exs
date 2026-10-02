# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ConsentStorageTest do
  use ExUnit.Case, async: false

  require Ecto.Query

  alias Arca.ConsentStorage
  alias Arca.ProfileStorage
  alias Arca.VaultStorage

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    actor = Arca.Test.Actor.local()
    {:ok, athanor: actor.athanor_id}
  end

  defp profile!(athanor, id) do
    {:ok, profile} =
      ProfileStorage.put(%{
        id: id,
        athanor_id: athanor,
        source_ref: "reagent:local.storage-test",
        kind: "owner",
        label: "default",
        status: "active"
      })

    profile
  end

  defp entry!(athanor) do
    {:ok, entry} =
      VaultStorage.put(%Prima.Actor{athanor_id: athanor}, %{
        name: "entry-#{System.unique_integer([:positive])}",
        kind: "api_key",
        sealed_payload: "sealed"
      })

    entry
  end

  defp consent_attrs(athanor, profile_id, revision) do
    %{
      athanor_id: athanor,
      profile_id: profile_id,
      revision: revision,
      scope: "versionless",
      pinned_version: "",
      invoke_mode: "open_inert",
      shape_digest: "sha256:shape",
      commit_digest: "sha256:commit",
      blob_digest: Prima.JCS.hash_binary("{}"),
      resolved_policy: "{}",
      activation: "{}",
      admitted_origins: [:interactive],
      granted_by: "test",
      granted_via: "bootstrap"
    }
  end

  describe "the blob digest is not optional" do
    test "a revision written without one raises rather than storing", %{athanor: athanor} do
      profile = profile!(athanor, "prof_no_digest")

      # What a caller can still hand the writer: the digest it read from a
      # commit that carries none, or an empty one. Attrs with no
      # `blob_digest` key at all are refused where they are written — the
      # writer takes a binary digest, and a caller that omits the key does
      # not compile.
      for carried <- [%{}, %{blob_digest: ""}] do
        attrs =
          Map.put(consent_attrs(athanor, profile.id, 1), :blob_digest, carried[:blob_digest])

        assert_raise ArgumentError, ~r/require a blob_digest/, fn ->
          ConsentStorage.insert_revision(attrs, [], nil)
        end
      end

      # Nothing unverifiable was stored, and the profile has no head.
      assert {:error, :no_head} =
               ConsentStorage.get_head(Prima.Actor.in_athanor(athanor), profile.id)

      assert Arca.Repo.aggregate(Arca.Schemas.Consent, :count) == 0
    end
  end

  describe "insert_revision/4" do
    test "revision + refs + head advance commit together", %{athanor: athanor} do
      profile = profile!(athanor, "prof_multi_1")
      entry = entry!(athanor)

      assert {:ok, consent} =
               ConsentStorage.insert_revision(
                 consent_attrs(athanor, profile.id, 1),
                 [%{vault_entry_id: entry.id, binding_digest: "sha256:b"}],
                 nil
               )

      {:ok, head, refs} = ConsentStorage.get_head(Prima.Actor.in_athanor(athanor), profile.id)
      assert head.id == consent.id
      assert [%{vault_entry_id: entry_id}] = refs
      assert entry_id == entry.id
    end

    test "a failing in-transaction verifier rolls back everything",
         %{athanor: athanor} do
      profile = profile!(athanor, "prof_multi_2")
      entry = entry!(athanor)

      assert {:error, :binding_went_stale} =
               ConsentStorage.insert_revision(
                 consent_attrs(athanor, profile.id, 1),
                 [%{vault_entry_id: entry.id, binding_digest: "sha256:b"}],
                 nil,
                 verify: fn -> {:error, :binding_went_stale} end
               )

      assert {:error, :no_head} =
               ConsentStorage.get_head(Prima.Actor.in_athanor(athanor), profile.id)

      assert Arca.Repo.aggregate(Arca.Schemas.Consent, :count) == 0
      assert Arca.Repo.aggregate(Arca.Schemas.ConsentVaultRef, :count) == 0
    end

    test "a stale head CAS refuses with head_moved and inserts nothing",
         %{athanor: athanor} do
      profile = profile!(athanor, "prof_multi_3")

      {:ok, first} =
        ConsentStorage.insert_revision(consent_attrs(athanor, profile.id, 1), [], nil)

      # Racing writer with a stale expectation (nil = "no head yet").
      assert {:error, :head_moved} =
               ConsentStorage.insert_revision(consent_attrs(athanor, profile.id, 2), [], nil)

      {:ok, head, _refs} = ConsentStorage.get_head(Prima.Actor.in_athanor(athanor), profile.id)
      assert head.id == first.id
      assert Arca.Repo.aggregate(Arca.Schemas.Consent, :count) == 1
    end

    test "a racing writer at the same revision is refused with head_moved, not raised",
         %{athanor: athanor} do
      profile = profile!(athanor, "prof_multi_5")

      {:ok, first} =
        ConsentStorage.insert_revision(consent_attrs(athanor, profile.id, 1), [], nil)

      assert {:error, :head_moved} =
               ConsentStorage.insert_revision(consent_attrs(athanor, profile.id, 1), [], nil)

      {:ok, head, _refs} = ConsentStorage.get_head(Prima.Actor.in_athanor(athanor), profile.id)
      assert head.id == first.id
      assert Arca.Repo.aggregate(Arca.Schemas.Consent, :count) == 1
    end

    test "a refs row violating the vault FK rolls the revision back",
         %{athanor: athanor} do
      profile = profile!(athanor, "prof_multi_4")

      assert {:error, _} =
               ConsentStorage.insert_revision(
                 consent_attrs(athanor, profile.id, 1),
                 [%{vault_entry_id: "vlt_never_existed", binding_digest: "sha256:b"}],
                 nil
               )

      assert {:error, :no_head} =
               ConsentStorage.get_head(Prima.Actor.in_athanor(athanor), profile.id)

      assert Arca.Repo.aggregate(Arca.Schemas.Consent, :count) == 0
    end
  end

  describe "mint_profile_with_revision/4" do
    test "profile and first revision are one atom", %{athanor: athanor} do
      entry = entry!(athanor)

      attrs = %{
        id: "prof_mint_1",
        athanor_id: athanor,
        source_ref: "reagent:local.minted",
        kind: "owner",
        label: "default",
        status: "active"
      }

      assert {:ok, consent} =
               ConsentStorage.mint_profile_with_revision(
                 attrs,
                 consent_attrs(athanor, "prof_mint_1", 1),
                 [%{vault_entry_id: entry.id, binding_digest: "sha256:b"}]
               )

      {:ok, profile} = ProfileStorage.get(Prima.Actor.in_athanor(athanor), "prof_mint_1")
      assert profile.head_consent_id == consent.id
    end

    test "a failed consent leg leaves NO orphan profile", %{athanor: athanor} do
      attrs = %{
        id: "prof_mint_2",
        athanor_id: athanor,
        source_ref: "reagent:local.orphanless",
        kind: "owner",
        label: "default",
        status: "active"
      }

      assert {:error, :nope} =
               ConsentStorage.mint_profile_with_revision(
                 attrs,
                 consent_attrs(athanor, "prof_mint_2", 1),
                 [],
                 verify: fn -> {:error, :nope} end
               )

      assert {:error, :not_found} =
               ProfileStorage.get(Prima.Actor.in_athanor(athanor), "prof_mint_2")
    end
  end

  describe "the read side answers the actor's own tenant" do
    # The two reads the consent domain used to reach through a swappable
    # source now come from here, actor-first. Another tenant's actor holding
    # the right ids is the case that proves the scope is the actor's and not
    # the argument's: a profile id and a source ref are guessable strings.
    test "another tenant's actor sees no profile, no head and no decoded consent",
         %{athanor: athanor} do
      profile = profile!(athanor, "prof_cross_tenant")
      entry = entry!(athanor)

      {:ok, _consent} =
        ConsentStorage.insert_revision(
          consent_attrs(athanor, profile.id, 1),
          [%{vault_entry_id: entry.id, binding_digest: "sha256:b"}],
          nil
        )

      mine = Prima.Actor.in_athanor(athanor)
      theirs = Prima.Actor.in_athanor(Arca.Test.Actor.athanor!("ath_other").id)

      assert {:ok, [_ | _]} = ConsentStorage.profiles(mine, "reagent:local.storage-test")
      assert {:ok, %{revision: 1}} = ConsentStorage.head_consent(mine, profile.id)
      assert {:ok, _head, _refs} = ConsentStorage.get_head(mine, profile.id)

      # `:not_found`, not `:no_head`: the profile row is not this tenant's at
      # all, which is a different fact from a profile of its own that has yet
      # to be granted, and the two must stay tellable apart.
      assert {:ok, []} = ConsentStorage.profiles(theirs, "reagent:local.storage-test")
      assert {:error, :not_found} = ConsentStorage.head_consent(theirs, profile.id)
      assert {:error, :not_found} = ConsentStorage.get_head(theirs, profile.id)
    end

    test "an actor with no athanor is refused, never answered with nothing",
         %{athanor: athanor} do
      profile = profile!(athanor, "prof_no_athanor")

      {:ok, _consent} =
        ConsentStorage.insert_revision(consent_attrs(athanor, profile.id, 1), [], nil)

      nobody = %Prima.Actor{}

      assert {:error, :no_athanor} = ConsentStorage.profiles(nobody, "reagent:local.storage-test")
      assert {:error, :no_athanor} = ConsentStorage.head_consent(nobody, profile.id)
    end
  end

  describe "profile_entries/2" do
    test "keeps an undecodable profile as a corrupt marker that profiles/2 drops", %{
      athanor: athanor
    } do
      _fine = profile!(athanor, "prof_entries_fine")

      {:ok, _damaged} =
        ProfileStorage.put(%{
          id: "prof_entries_damaged",
          athanor_id: athanor,
          source_ref: "reagent:local.storage-test",
          kind: "owner",
          label: "damaged",
          status: "active"
        })

      {1, _} =
        Arca.Repo.update_all(
          Ecto.Query.from(p in Arca.Schemas.Profile, where: p.id == "prof_entries_damaged"),
          set: [status: "sideways"]
        )

      actor = %Prima.Actor{athanor_id: athanor}

      assert {:ok, entries} = ConsentStorage.profile_entries(actor, "reagent:local.storage-test")
      assert %{id: "prof_entries_damaged", status: :corrupt} in entries
      assert Enum.any?(entries, &match?(%{id: "prof_entries_fine", kind: :owner}, &1))

      assert {:ok, [%{id: "prof_entries_fine"}]} =
               ConsentStorage.profiles(actor, "reagent:local.storage-test")
    end
  end

  describe "admitted origins" do
    test "are written with the revision and read back with it", %{athanor: athanor} do
      profile = profile!(athanor, "prof_origins")

      attrs =
        consent_attrs(athanor, profile.id, 1)
        |> Map.put(:admitted_origins, ["schedule", :interactive])

      assert {:ok, _} = ConsentStorage.insert_revision(attrs, [], nil)

      assert {:ok, %{admitted_origins: [:interactive, :schedule]}} =
               ConsentStorage.head_consent(Prima.Actor.in_athanor(athanor), profile.id)
    end

    test "an empty list, a duplicate or an origin outside the enum is refused", %{
      athanor: athanor
    } do
      profile = profile!(athanor, "prof_bad_origins")

      for origins <- [nil, [], ["interactive", "interactive"], ["batch"], "interactive"] do
        attrs = Map.put(consent_attrs(athanor, profile.id, 1), :admitted_origins, origins)

        assert {:error, {:invalid, %{admitted_origins: [_]}}} =
                 ConsentStorage.insert_revision(attrs, [], nil)
      end

      assert Arca.Repo.aggregate(Arca.Schemas.Consent, :count) == 0
    end

    test "a revision written without them is refused, and a stored one with none does not decode",
         %{athanor: athanor} do
      profile = profile!(athanor, "prof_no_origins")
      attrs = Map.delete(consent_attrs(athanor, profile.id, 1), :admitted_origins)

      assert {:error, {:invalid, %{admitted_origins: [_]}}} =
               ConsentStorage.insert_revision(attrs, [], nil)

      assert {:error, {:invalid, %{admitted_origins: [_]}}} =
               ConsentStorage.mint_profile_with_revision(
                 %{
                   id: "prof_no_origins_minted",
                   athanor_id: athanor,
                   source_ref: "reagent:local.storage-test-minted",
                   kind: "owner",
                   label: "default",
                   status: "active"
                 },
                 Map.put(attrs, :profile_id, "prof_no_origins_minted"),
                 []
               )

      assert Arca.Repo.aggregate(Arca.Schemas.Consent, :count) == 0
      refute Arca.Repo.get(Arca.Schemas.Profile, "prof_no_origins_minted")

      # A row reached past the writer — a hand edit, a restored backup —
      # admits nothing: no reader meets a revision with no origins.
      {:ok, consent} =
        ConsentStorage.insert_revision(consent_attrs(athanor, profile.id, 1), [], nil)

      {1, _} =
        Arca.Repo.update_all(
          Ecto.Query.from(c in Arca.Schemas.Consent, where: c.id == ^consent.id),
          set: [admitted_origins: nil]
        )

      assert {:error, {:invalid_stored_value, :admitted_origins}} =
               ConsentStorage.head_consent(Prima.Actor.in_athanor(athanor), profile.id)

      assert {:ok, [], false} =
               ConsentStorage.active_heads(Prima.Actor.in_athanor(athanor), limit: 10)
    end

    test "a stored list that does not parse refuses the consent", %{athanor: athanor} do
      profile = profile!(athanor, "prof_corrupt_origins")

      {:ok, consent} =
        ConsentStorage.insert_revision(consent_attrs(athanor, profile.id, 1), [], nil)

      {1, _} =
        Arca.Repo.update_all(
          Ecto.Query.from(c in Arca.Schemas.Consent, where: c.id == ^consent.id),
          set: [admitted_origins: ~s(["batch"])]
        )

      assert {:error, {:invalid_stored_value, :admitted_origins}} =
               ConsentStorage.head_consent(Prima.Actor.in_athanor(athanor), profile.id)
    end
  end

  describe "active_heads/2" do
    defp granted!(athanor, id, status, refs \\ []) do
      {:ok, _profile} =
        ProfileStorage.put(%{
          id: id,
          athanor_id: athanor,
          source_ref: "reagent:local.#{id}",
          kind: "owner",
          label: "default",
          status: "active"
        })

      {:ok, consent} =
        ConsentStorage.insert_revision(consent_attrs(athanor, id, 1), refs, nil)

      if status != "active",
        do: :ok = ProfileStorage.set_status(Prima.Actor.in_athanor(athanor), id, status)

      consent
    end

    test "answers each active profile with its head revision and that revision's refs",
         %{athanor: athanor} do
      entry = entry!(athanor)
      ref = %{vault_entry_id: entry.id, binding_digest: "sha256:b"}

      first = granted!(athanor, "prof_heads_a", "active", [ref])
      _second = granted!(athanor, "prof_heads_b", "active")
      _waiting = granted!(athanor, "prof_heads_c", "needs_consent", [ref])
      _revoked = granted!(athanor, "prof_heads_d", "revoked", [ref])

      # A profile with no revision yet roots nothing.
      _headless = profile!(athanor, "prof_heads_e")

      assert {:ok, [a, b], false} =
               ConsentStorage.active_heads(Prima.Actor.in_athanor(athanor), limit: 10)

      assert %{
               profile: %{id: "prof_heads_a", kind: :owner, status: :active},
               consent: %{id: consent_id, revision: 1, vault_refs: [%{vault_entry_id: id}]}
             } = a

      assert consent_id == first.id
      assert id == entry.id
      assert %{profile: %{id: "prof_heads_b"}, consent: %{vault_refs: []}} = b
    end

    test "reads the head alone: a later revision's refs, never an earlier one's",
         %{athanor: athanor} do
      entry = entry!(athanor)
      first = granted!(athanor, "prof_heads_moved", "active")

      {:ok, second} =
        ConsentStorage.insert_revision(
          consent_attrs(athanor, "prof_heads_moved", 2),
          [%{vault_entry_id: entry.id, binding_digest: "sha256:b"}],
          first.id
        )

      assert {:ok, [%{consent: head}], false} =
               ConsentStorage.active_heads(Prima.Actor.in_athanor(athanor), limit: 10)

      assert head.id == second.id
      assert head.revision == 2
      assert [%{vault_entry_id: id}] = head.vault_refs
      assert id == entry.id
    end

    test "drops a row that does not decode, and keeps the rest", %{athanor: athanor} do
      _fine = granted!(athanor, "prof_heads_fine", "active")
      damaged = granted!(athanor, "prof_heads_damaged", "active")
      _odd_kind = granted!(athanor, "prof_heads_kind", "active")

      {1, _} =
        Arca.Repo.update_all(
          Ecto.Query.from(c in Arca.Schemas.Consent, where: c.id == ^damaged.id),
          set: [scope: "sideways"]
        )

      {1, _} =
        Arca.Repo.update_all(
          Ecto.Query.from(p in Arca.Schemas.Profile, where: p.id == "prof_heads_kind"),
          set: [kind: "sideways"]
        )

      assert {:ok, [%{profile: %{id: "prof_heads_fine"}}], false} =
               ConsentStorage.active_heads(Prima.Actor.in_athanor(athanor), limit: 10)
    end

    test "answers the actor's own athanor, and refuses an actor with none", %{athanor: athanor} do
      _mine = granted!(athanor, "prof_heads_mine", "active")
      theirs = Prima.Actor.in_athanor(Arca.Test.Actor.athanor!("ath_other").id)

      assert {:ok, [%{profile: %{id: "prof_heads_mine"}}], false} =
               ConsentStorage.active_heads(Prima.Actor.in_athanor(athanor), limit: 10)

      assert {:ok, [], false} = ConsentStorage.active_heads(theirs, limit: 10)

      for nobody <- [%Prima.Actor{}, %Prima.Actor{athanor_id: ""}] do
        assert {:error, :no_athanor} = ConsentStorage.active_heads(nobody, limit: 10)
      end
    end

    test "reads at most the limit in profile-id order, and says when more stand past it",
         %{athanor: athanor} do
      for id <- ~w(prof_limit_a prof_limit_b prof_limit_c), do: granted!(athanor, id, "active")
      actor = Prima.Actor.in_athanor(athanor)

      assert {:ok, heads, true} = ConsentStorage.active_heads(actor, limit: 1)
      assert Enum.map(heads, & &1.profile.id) == ["prof_limit_a"]

      assert {:ok, heads, true} = ConsentStorage.active_heads(actor, limit: 2)
      assert Enum.map(heads, & &1.profile.id) == ["prof_limit_a", "prof_limit_b"]

      # Exactly the limit is all there is.
      assert {:ok, heads, false} = ConsentStorage.active_heads(actor, limit: 3)
      assert Enum.map(heads, & &1.profile.id) == ["prof_limit_a", "prof_limit_b", "prof_limit_c"]
    end

    test "a row that does not decode still counts toward the limit", %{athanor: athanor} do
      damaged = granted!(athanor, "prof_limit_damaged_a", "active")
      _second = granted!(athanor, "prof_limit_damaged_b", "active")
      _third = granted!(athanor, "prof_limit_damaged_c", "active")

      {1, _} =
        Arca.Repo.update_all(
          Ecto.Query.from(c in Arca.Schemas.Consent, where: c.id == ^damaged.id),
          set: [scope: "sideways"]
        )

      assert {:ok, [%{profile: %{id: "prof_limit_damaged_b"}}], true} =
               ConsentStorage.active_heads(Prima.Actor.in_athanor(athanor), limit: 2)
    end
  end

  describe "active_head_policies/2" do
    defp head_in!(athanor, id, status) do
      {:ok, _profile} =
        ProfileStorage.put(%{
          id: id,
          athanor_id: athanor,
          source_ref: "reagent:local.#{id}",
          kind: "owner",
          label: "default",
          status: "active"
        })

      {:ok, _consent} =
        ConsentStorage.insert_revision(consent_attrs(athanor, id, 1), [], nil)

      if status != "active",
        do: :ok = ProfileStorage.set_status(Prima.Actor.in_athanor(athanor), id, status)

      :ok
    end

    test "pages every athanor's active heads in profile-id order, each naming its own athanor",
         %{athanor: athanor} do
      :ok = head_in!(athanor, "prof_pol_a", "active")
      :ok = head_in!("ath_pol_other", "prof_pol_b", "active")
      :ok = head_in!(athanor, "prof_pol_c", "active")
      :ok = head_in!(athanor, "prof_pol_d", "revoked")
      :ok = head_in!("ath_pol_other", "prof_pol_e", "needs_consent")
      _headless = profile!(athanor, "prof_pol_f")

      assert {:ok, [first, second]} = ConsentStorage.active_head_policies(nil, 2)

      assert %{
               athanor_id: ^athanor,
               profile_id: "prof_pol_a",
               source_ref: "reagent:local.prof_pol_a",
               revision: 1,
               resolved_policy: "{}"
             } = first

      assert %{athanor_id: "ath_pol_other", profile_id: "prof_pol_b"} = second

      assert {:ok, [%{athanor_id: ^athanor, profile_id: "prof_pol_c"}]} =
               ConsentStorage.active_head_policies("prof_pol_b", 2)

      assert {:ok, []} = ConsentStorage.active_head_policies("prof_pol_c", 2)
    end
  end

  describe "insert-only surface" do
    test "the module still exports no update function" do
      exported =
        Arca.ConsentStorage.__info__(:functions)
        |> Enum.map(fn {name, _arity} -> Atom.to_string(name) end)

      refute Enum.any?(exported, &String.starts_with?(&1, "update"))
    end
  end
end
