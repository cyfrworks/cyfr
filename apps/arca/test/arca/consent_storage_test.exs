# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ConsentStorageTest do
  use ExUnit.Case, async: false

  require Ecto.Query
  require Arca.Repo.Errors

  alias Arca.ConsentStorage
  alias Arca.ProfileStorage
  alias Arca.Test.Writers
  alias Arca.VaultStorage

  @key "reagent:local.storage-test|@ingress|default"
  @second_key "reagent:local.storage-test|reagent:local.dep|default"
  @standing_key "reagent:local.storage-test|reagent:local.standing|default"

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    actor = Arca.Test.Actor.local()
    {:ok, athanor: actor.athanor_id}
  end

  defp profile!(athanor, id) do
    {:ok, profile} =
      Writers.put_profile(%{
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
        sealed_payload: "sealed",
        destination: ~s({"hosts":["api.example.com"],"scheme":"https"})
      })

    entry
  end

  # The source's own binding of `entry_id`, standing, or `over` beside it.
  defp ref(entry_id, over \\ %{}) do
    Map.merge(
      %{
        binding_key: "reagent:local.storage-test|@ingress|default",
        vault_entry_id: entry_id,
        binding_digest: "sha256:b"
      },
      over
    )
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
      blob_digest: Prima.Digest.sha256("{}"),
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
                 [ref(entry.id)],
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
                 [ref(entry.id)],
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
                 [ref("vlt_never_existed")],
                 nil
               )

      assert {:error, :no_head} =
               ConsentStorage.get_head(Prima.Actor.in_athanor(athanor), profile.id)

      assert Arca.Repo.aggregate(Arca.Schemas.Consent, :count) == 0
    end

    test "reactivate moves a needs_consent profile to active with the revision, and no other " <>
           "status; without it a blocked profile stays blocked",
         %{athanor: athanor} do
      actor = Prima.Actor.in_athanor(athanor)

      for {label, status, reactivate, expected} <- [
            {"blocked", "needs_consent", true, "active"},
            {"revoked", "revoked", true, "revoked"},
            {"running", "active", true, "active"},
            {"unasked", "needs_consent", false, "needs_consent"}
          ] do
        {:ok, profile} =
          Writers.put_profile(%{
            id: "prof_reactivate_#{label}",
            athanor_id: athanor,
            source_ref: "reagent:local.reactivate-#{label}",
            kind: "owner",
            label: "default",
            status: "active"
          })

        {:ok, first} =
          ConsentStorage.insert_revision(consent_attrs(athanor, profile.id, 1), [], nil)

        # The profile is minted active; it moves only to another status.
        if status != "active",
          do: :ok = ProfileStorage.transition(actor, profile.id, :any, status)

        assert {:ok, second} =
                 ConsentStorage.insert_revision(
                   consent_attrs(athanor, profile.id, 2),
                   [],
                   first.id,
                   reactivate: reactivate
                 )

        assert {:ok, %{status: ^expected, head_consent_id: head}} =
                 ProfileStorage.get(actor, profile.id)

        assert head == second.id, "#{label}: the head advanced"
      end

      # A revision refused writes no status either.
      {:ok, refused} = ProfileStorage.get(actor, "prof_reactivate_blocked")
      :ok = ProfileStorage.transition(actor, refused.id, :any, "needs_consent")

      assert {:error, :head_moved} =
               ConsentStorage.insert_revision(
                 consent_attrs(athanor, refused.id, 3),
                 [],
                 "cons_not_the_head",
                 reactivate: true
               )

      assert {:ok, %{status: "needs_consent"}} = ProfileStorage.get(actor, refused.id)
    end
  end

  describe "the athanor's own entries a revision binds" do
    test "an active one is bound; one not active, without a row or another athanor's " <>
           "writes nothing",
         %{athanor: athanor} do
      actor = Prima.Actor.in_athanor(athanor)
      profile = profile!(athanor, "prof_own_1")
      active = entry!(athanor)

      assert {:ok, _} =
               ConsentStorage.insert_revision(
                 consent_attrs(athanor, profile.id, 1),
                 [ref(active.id)],
                 nil
               )

      {:ok, head, _refs} = ConsentStorage.get_head(actor, profile.id)

      revoked = entry!(athanor)
      {:ok, _} = VaultStorage.set_status(actor, revoked.id, "revoked")
      reauth = entry!(athanor)
      {:ok, _} = VaultStorage.set_status(actor, reauth.id, "needs_reauth")
      gone = entry!(athanor)
      {:ok, _} = VaultStorage.tombstone(actor, gone.id)
      elsewhere = entry!("ath_other")

      for {id, refusal} <- [
            {revoked.id, {:entry_unavailable, "revoked"}},
            {reauth.id, {:entry_unavailable, "needs_reauth"}},
            {gone.id, {:entry_unavailable, "tombstoned"}},
            {"vlt_never_existed", :not_found},
            {elsewhere.id, :not_found}
          ] do
        assert {:error, ^refusal} =
                 ConsentStorage.insert_revision(
                   consent_attrs(athanor, profile.id, 2),
                   [ref(id)],
                   head.id
                 )

        # The first commit of a profile is held to the same.
        minted = "prof_own_mint_#{System.unique_integer([:positive])}"

        assert {:error, ^refusal} =
                 ConsentStorage.mint_profile_with_revision(
                   %{
                     id: minted,
                     athanor_id: athanor,
                     source_ref: "reagent:local.storage-test",
                     kind: "owner",
                     label: "mint-#{System.unique_integer([:positive])}",
                     status: "active"
                   },
                   consent_attrs(athanor, minted, 1),
                   [ref(id)]
                 )

        assert {:error, :not_found} = ProfileStorage.get(actor, minted)
      end

      {:ok, still, refs} = ConsentStorage.get_head(actor, profile.id)
      assert still.id == head.id
      assert [%{vault_entry_id: id}] = refs
      assert id == active.id
      assert Arca.Repo.aggregate(Arca.Schemas.Consent, :count) == 1
    end
  end

  describe "the shares a revision binds" do
    setup do
      terry = Arca.Test.Shares.owner!()
      entry = Arca.Test.Shares.entry!(terry.actor)
      share = Arca.Test.Shares.share!(terry.actor, entry.id)
      alice = Arca.Test.Shares.owner!()
      {:ok, terry: terry, entry: entry, share: share, alice: alice}
    end

    defp share_revision(athanor, refs, profile \\ nil) do
      n = System.unique_integer([:positive])

      profile =
        profile ||
          elem(
            Writers.put_profile(%{
              id: "prof_sh_#{n}",
              athanor_id: athanor,
              source_ref: "reagent:local.share-#{n}",
              kind: "owner",
              label: "default",
              status: "active"
            }),
            1
          )

      {profile, ConsentStorage.insert_revision(consent_attrs(athanor, profile.id, 1), refs, nil)}
    end

    test "a share-only binding is stored and read back under the share scope",
         %{share: share, alice: alice} do
      athanor = alice.athanor.id
      ref = Arca.Test.Shares.share_ref(share.id)
      {profile, {:ok, _consent}} = share_revision(athanor, [ref])

      {:ok, head} = ConsentStorage.head_consent(actor(athanor), profile.id)

      assert [
               %{
                 scope: "share",
                 share_id: share_id,
                 vault_entry_id: nil,
                 via_label: nil,
                 binding_digest: "sha256:d0"
               } = row
             ] = head.vault_refs

      assert share_id == share.id

      assert ConsentStorage.row_identity(row) ==
               {:share, ref.binding_key, share.id, "sha256:d0"}
    end

    test "a binding naming a share beside another identity, with no digest or with no audience " <>
           "it was admitted under is refused",
         %{share: share, entry: entry, alice: alice} do
      ref = Arca.Test.Shares.share_ref(share.id)

      for bad <- [
            Map.put(ref, :vault_entry_id, entry.id),
            Map.put(ref, :via_label, "default"),
            Map.delete(ref, :binding_digest),
            Map.delete(ref, :admitted),
            Map.put(ref, :admitted, %{audience: "group", group_id: nil})
          ] do
        assert {_profile, {:error, {:invalid, %{vault_refs: [_ | _]}}}} =
                 share_revision(alice.athanor.id, [bad]),
               inspect(bad)
      end

      assert Arca.Repo.aggregate(Arca.Schemas.Consent, :count) == 0
    end

    test "a revoked share, an unknown one, a stale digest, a source no longer active and a " <>
           "revision outside a person's own athanor write nothing",
         %{terry: terry, entry: entry, share: share, alice: alice} do
      revoked_entry = Arca.Test.Shares.entry!(terry.actor)
      revoked = Arca.Test.Shares.share!(terry.actor, revoked_entry.id)
      {:ok, _} = Arca.Shares.revoke(terry.actor, revoked.id, "needs_consent")
      reauth_entry = Arca.Test.Shares.entry!(terry.actor)
      reauth = Arca.Test.Shares.share!(terry.actor, reauth_entry.id)
      {:ok, _} = VaultStorage.set_status(terry.actor, reauth_entry.id, "needs_reauth")
      group = Arca.Test.Shares.group!([alice.user.id])

      for {athanor, ref, refusal} <- [
            {alice.athanor.id, Arca.Test.Shares.share_ref(revoked.id),
             {:share_unavailable, "revoked"}},
            {alice.athanor.id, Arca.Test.Shares.share_ref("shr_none"), :not_found},
            {alice.athanor.id, Arca.Test.Shares.share_ref(share.id, "sha256:old"),
             {:binding_went_stale, share.id}},
            {alice.athanor.id, Arca.Test.Shares.share_ref(reauth.id),
             {:entry_unavailable, "needs_reauth"}},
            {group.id, Arca.Test.Shares.share_ref(share.id), :not_own_athanor}
          ] do
        assert {_profile, {:error, ^refusal}} = share_revision(athanor, [ref]), inspect(refusal)
      end

      assert Arca.Repo.aggregate(Arca.Schemas.Consent, :count) == 0
      assert {:ok, %{binding_digest: "sha256:d0"}} = VaultStorage.get(terry.actor, entry.id)
    end

    test "a share whose audience moved from the one its binding was admitted under is " <>
           "refused under the lock, and the audience it holds is admitted",
         %{terry: terry, share: share, alice: alice} do
      group = Arca.Test.Shares.group!([terry.user.id])
      narrowed = %{audience: "group", group_id: group.id}

      {:ok, _} =
        Arca.Shares.set_audience(terry.actor, share.id, Arca.Test.Shares.everyone(), narrowed)

      for admitted <- [Arca.Test.Shares.everyone(), %{narrowed | group_id: "ath_other"}] do
        ref = Arca.Test.Shares.share_ref(share.id, "sha256:d0", admitted)

        assert {_profile, {:error, {:audience_changed, id}}} =
                 share_revision(alice.athanor.id, [ref]),
               inspect(admitted)

        assert id == share.id
      end

      assert Arca.Repo.aggregate(Arca.Schemas.Consent, :count) == 0

      assert {_profile, {:ok, _consent}} =
               share_revision(alice.athanor.id, [
                 Arca.Test.Shares.share_ref(share.id, "sha256:d0", narrowed)
               ])
    end

    test "an own entry and a share bind together, each locked in its order",
         %{share: share, alice: alice} do
      own = Arca.Test.Shares.entry!(alice.actor)

      {profile, {:ok, _}} =
        share_revision(alice.athanor.id, [
          ref(own.id, %{binding_key: @second_key, binding_digest: "sha256:d0"}),
          Arca.Test.Shares.share_ref(share.id)
        ])

      {:ok, head} = ConsentStorage.head_consent(actor(alice.athanor.id), profile.id)

      assert Enum.sort(Enum.map(head.vault_refs, &(&1.share_id || &1.vault_entry_id))) ==
               Enum.sort([own.id, share.id])
    end
  end

  describe "who a revision binding a share is granted by" do
    setup do
      terry = Arca.Test.Shares.owner!()
      share = Arca.Test.Shares.share!(terry.actor, Arca.Test.Shares.entry!(terry.actor).id)
      {:ok, share: share, alice: Arca.Test.Shares.owner!(), bob: Arca.Test.Shares.owner!()}
    end

    defp granted(athanor, granted_by) do
      n = System.unique_integer([:positive])
      profile_id = "prof_by_#{n}"

      profile = %{
        id: profile_id,
        athanor_id: athanor,
        source_ref: "reagent:local.by-#{n}",
        kind: "owner",
        label: "default",
        status: "active"
      }

      {profile, Map.put(consent_attrs(athanor, profile_id, 1), :granted_by, granted_by)}
    end

    test "a person binds in their own athanor alone, on both writers; a revision with no " <>
           "person binds by the athanor's kind",
         %{share: share, alice: alice, bob: bob} do
      ref = Arca.Test.Shares.share_ref(share.id)

      # Alice's athanor, a grant attributed to Bob.
      {profile, attrs} = granted(alice.athanor.id, bob.user.id)
      {:ok, _} = Writers.put_profile(profile)

      assert {:error, :not_own_athanor} = ConsentStorage.insert_revision(attrs, [ref], nil)

      {minted, mint_attrs} = granted(alice.athanor.id, bob.user.id)

      assert {:error, :not_own_athanor} =
               ConsentStorage.mint_profile_with_revision(minted, mint_attrs, [ref])

      assert {:error, :not_found} = ProfileStorage.get(actor(alice.athanor.id), minted.id)
      assert Arca.Repo.aggregate(Arca.Schemas.Consent, :count) == 0

      # Alice's own grant, and the bootstrap's with no person, bind.
      {profile, attrs} = granted(alice.athanor.id, alice.user.id)
      {:ok, _} = Writers.put_profile(profile)
      assert {:ok, _} = ConsentStorage.insert_revision(attrs, [ref], nil)

      {minted, mint_attrs} = granted(alice.athanor.id, "system:bootstrap")
      assert {:ok, _} = ConsentStorage.mint_profile_with_revision(minted, mint_attrs, [ref])
      assert Arca.Repo.aggregate(Arca.Schemas.Consent, :count) == 2
    end
  end

  describe "block_dependents/4 and share_heads/2 answer their caller's own" do
    setup do
      terry = Arca.Test.Shares.owner!()
      entry = Arca.Test.Shares.entry!(terry.actor)
      share = Arca.Test.Shares.share!(terry.actor, entry.id)
      alice = Arca.Test.Shares.owner!()
      profile = Arca.Test.Shares.bound!(alice.athanor.id, share.id)
      {:ok, terry: terry, entry: entry, share: share, alice: alice, profile: profile}
    end

    test "another athanor's actor naming the share or the entry is refused and blocks nothing",
         %{terry: terry, entry: entry, share: share, alice: alice, profile: profile} do
      stranger = Prima.Actor.in_athanor(alice.athanor.id)

      assert {:error, :cross_tenant} =
               ConsentStorage.block_dependents(stranger, nil, [share.id], "needs_consent")

      assert {:error, :cross_tenant} =
               ConsentStorage.block_dependents(
                 stranger,
                 {terry.athanor.id, entry.id},
                 [],
                 "needs_consent"
               )

      assert {:error, :cross_tenant} = ConsentStorage.share_heads(stranger, [share.id])
      assert {:error, :cross_tenant} = ConsentStorage.share_heads(%Prima.Actor{}, [share.id])
      # Called through apply/3: the type checker refuses the literal call.
      assert_raise FunctionClauseError, fn ->
        apply(ConsentStorage, :share_heads, [nil, [share.id]])
      end

      assert Arca.Test.Shares.profile_status(alice.athanor.id, profile.id) == "active"

      # The owner and the platform reach them.
      pair = {alice.athanor.id, profile.id}
      assert {:ok, [^pair]} = ConsentStorage.share_heads(terry.actor, [share.id])
      assert {:ok, [^pair]} = ConsentStorage.share_heads(Prima.Actor.system(), [share.id])

      assert {:ok, [^pair]} =
               ConsentStorage.block_dependents(
                 Prima.Actor.in_athanor(terry.athanor.id),
                 nil,
                 [share.id],
                 "needs_consent"
               )

      assert Arca.Test.Shares.profile_status(alice.athanor.id, profile.id) == "needs_consent"
    end
  end

  describe "a binding key is stored whole on either adapter" do
    # A publisher namespace of 54 characters and names of 64: both refs
    # are valid and the source ref fits `profiles.source_ref`, while the
    # dependency binding's key is 264 characters.
    @publisher "connectors.enterprise-integration-platform.example.com"
    @node "catalyst:" <> @publisher <> "." <> String.duplicate("n", 64)
    @dep "reagent:" <> @publisher <> "." <> String.duplicate("d", 64)

    test "a dependency binding key the grammar admits, over 255 characters", %{athanor: athanor} do
      assert {:ok, %Prima.ComponentRef{}} = Prima.ComponentRef.parse(@node)
      assert {:ok, %Prima.ComponentRef{}} = Prima.ComponentRef.parse(@dep)

      key = Prima.Authority.Blob.binding_key(@node, @dep, nil)
      assert {:ok, {@node, @dep, nil}} = Prima.Authority.Blob.parse_binding_key(key)
      assert String.length(key) > 255

      {:ok, profile} =
        Writers.put_profile(%{
          id: "prof_bk_#{System.unique_integer([:positive])}",
          athanor_id: athanor,
          source_ref: @node,
          kind: "owner",
          label: "default",
          status: "active"
        })

      entry = entry!(athanor)

      assert {:ok, _consent} =
               ConsentStorage.insert_revision(
                 consent_attrs(athanor, profile.id, 1),
                 [ref(entry.id, %{binding_key: key})],
                 nil
               )

      assert {:ok, %{vault_refs: [%{binding_key: ^key}]}} =
               ConsentStorage.head_consent(%Prima.Actor{athanor_id: athanor}, profile.id)
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
                 [ref(entry.id)]
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
    # The consent domain reads a component's profiles and a profile's head
    # consent here, actor-first. Another tenant's actor holding
    # the right ids is the case that proves the scope is the actor's and not
    # the argument's: a profile id and a source ref are guessable strings.
    test "another tenant's actor sees no profile, no head and no decoded consent",
         %{athanor: athanor} do
      profile = profile!(athanor, "prof_cross_tenant")
      entry = entry!(athanor)

      {:ok, _consent} =
        ConsentStorage.insert_revision(
          consent_attrs(athanor, profile.id, 1),
          [ref(entry.id)],
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
        Writers.put_profile(%{
          id: "prof_entries_damaged",
          athanor_id: athanor,
          source_ref: "reagent:local.storage-test",
          kind: "owner",
          label: "damaged",
          status: "active"
        })

      # A status outside the vocabulary cannot be stored (its CHECK); a
      # kind outside it is the damage a read can still meet.
      {1, _} =
        Arca.Repo.update_all(
          Ecto.Query.from(p in Arca.Schemas.Profile, where: p.id == "prof_entries_damaged"),
          set: [kind: "sideways"]
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

    test "a revision written without them is refused", %{athanor: athanor} do
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
        Writers.put_profile(%{
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
        do: :ok = ProfileStorage.transition(Prima.Actor.in_athanor(athanor), id, :any, status)

      consent
    end

    test "answers each active profile with its head revision and that revision's refs",
         %{athanor: athanor} do
      entry = entry!(athanor)
      ref = ref(entry.id)

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
          [ref(entry.id)],
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

  describe "insert-only surface" do
    test "the module still exports no update function" do
      exported =
        Arca.ConsentStorage.__info__(:functions)
        |> Enum.map(fn {name, _arity} -> Atom.to_string(name) end)

      refute Enum.any?(exported, &String.starts_with?(&1, "update"))
    end
  end

  # ---------------------------------------------------------------------------
  # Bindings: one row per binding key, each with its own lifetime
  # ---------------------------------------------------------------------------

  describe "a ref is one binding" do
    test "two rows of one consent may name one entry under two keys, each with its lifetime",
         %{athanor: athanor} do
      profile = profile!(athanor, "prof_two_keys")
      entry = entry!(athanor)
      expires = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert {:ok, consent} =
               ConsentStorage.insert_revision(
                 consent_attrs(athanor, profile.id, 1),
                 [
                   ref(entry.id),
                   ref(entry.id, %{
                     binding_key: "reagent:local.storage-test|reagent:local.dep|default",
                     lifetime_kind: "until",
                     expires_at: expires
                   }),
                   ref(entry.id, %{
                     binding_key: "reagent:local.storage-test|reagent:local.other|default",
                     lifetime_kind: "once"
                   })
                 ],
                 nil
               )

      {:ok, head} = ConsentStorage.head_consent(actor(athanor), profile.id)
      assert head.id == consent.id

      lifetimes = Map.new(head.vault_refs, &{&1.binding_key, &1.lifetime_kind})

      assert lifetimes == %{
               "reagent:local.storage-test|@ingress|default" => "standing",
               "reagent:local.storage-test|reagent:local.dep|default" => "until",
               "reagent:local.storage-test|reagent:local.other|default" => "once"
             }

      assert Enum.all?(head.vault_refs, &(&1.vault_entry_id == entry.id))
    end

    test "Alice→Supabase and Bob→Supabase in one consent are two keys and two rows",
         %{athanor: athanor} do
      profile = profile!(athanor, "prof_alice_bob")
      entry = entry!(athanor)

      assert {:ok, _} =
               ConsentStorage.insert_revision(
                 consent_attrs(athanor, profile.id, 1),
                 [
                   ref(entry.id, %{binding_key: "catalyst:local.alice|supabase:x|default"}),
                   ref(entry.id, %{binding_key: "catalyst:local.bob|supabase:x|default"})
                 ],
                 nil
               )

      {:ok, head} = ConsentStorage.head_consent(actor(athanor), profile.id)

      assert Enum.sort(Enum.map(head.vault_refs, & &1.binding_key)) == [
               "catalyst:local.alice|supabase:x|default",
               "catalyst:local.bob|supabase:x|default"
             ]
    end

    test "an account named default beside the unnamed binding is two slots and two rows",
         %{athanor: athanor} do
      profile = profile!(athanor, "prof_default_name")
      entry = entry!(athanor)
      other = entry!(athanor)

      assert {:ok, _} =
               ConsentStorage.insert_revision(
                 consent_attrs(athanor, profile.id, 1),
                 [
                   ref(entry.id),
                   ref(other.id, %{
                     binding_key: "reagent:local.storage-test|@ingress|name:default"
                   })
                 ],
                 nil
               )

      {:ok, head} = ConsentStorage.head_consent(actor(athanor), profile.id)

      assert Enum.sort(Enum.map(head.vault_refs, & &1.binding_key)) == [
               "reagent:local.storage-test|@ingress|default",
               "reagent:local.storage-test|@ingress|name:default"
             ]
    end

    test "two rows with one binding key are refused, and nothing is written",
         %{athanor: athanor} do
      profile = profile!(athanor, "prof_dup_key")
      entry = entry!(athanor)
      other = entry!(athanor)

      assert {:error, {:invalid, %{vault_refs: ["names a binding key twice"]}}} =
               ConsentStorage.insert_revision(
                 consent_attrs(athanor, profile.id, 1),
                 [ref(entry.id), ref(other.id)],
                 nil
               )

      assert {:error, :no_head} = ConsentStorage.get_head(actor(athanor), profile.id)
    end

    test "an until without its expiry, or a once with one, is refused", %{athanor: athanor} do
      profile = profile!(athanor, "prof_bad_lifetime")
      entry = entry!(athanor)
      at = DateTime.add(DateTime.utc_now(), 60, :second)

      for bad <- [
            %{lifetime_kind: "until"},
            %{lifetime_kind: "once", expires_at: at},
            %{lifetime_kind: "standing", expires_at: at},
            %{lifetime_kind: "forever"}
          ] do
        assert {:error, {:invalid, %{vault_refs: [_ | _]}}} =
                 ConsentStorage.insert_revision(
                   consent_attrs(athanor, profile.id, 1),
                   [ref(entry.id, bad)],
                   nil
                 )
      end

      assert {:error, :no_head} = ConsentStorage.get_head(actor(athanor), profile.id)
    end

    test "a ref naming two of an entry, a share and a selection, or none, is refused",
         %{athanor: athanor} do
      profile = profile!(athanor, "prof_names_one")
      entry = entry!(athanor)

      for bad <- [
            ref(entry.id, %{share_id: "shr_x"}),
            ref(entry.id, %{via_label: "default"}),
            ref(nil),
            ref(nil, %{share_id: "shr_x", via_label: "x"}),
            ref(entry.id, %{binding_digest: nil})
          ] do
        assert {:error, {:invalid, %{vault_refs: [_ | _]}}} =
                 ConsentStorage.insert_revision(
                   consent_attrs(athanor, profile.id, 1),
                   [bad],
                   nil
                 )
      end

      assert {:error, :no_head} = ConsentStorage.get_head(actor(athanor), profile.id)
    end

    test "the baseline's check refuses a row naming two, or none, written around the changeset",
         %{athanor: athanor} do
      profile = profile!(athanor, "prof_raw_refs")
      entry = entry!(athanor)

      {:ok, consent} =
        ConsentStorage.insert_revision(consent_attrs(athanor, profile.id, 1), [], nil)

      row = %{
        consent_id: consent.id,
        athanor_id: athanor,
        binding_key: "k|@ingress|default",
        vault_entry_id: nil,
        share_id: nil,
        via_label: nil,
        binding_digest: "sha256:b",
        lifetime_kind: "standing",
        expires_at: nil
      }

      for {bad, key} <- [
            {%{row | vault_entry_id: entry.id, share_id: "shr_x"}, "a"},
            {%{row | vault_entry_id: entry.id, via_label: "default"}, "b"},
            {row, "c"},
            {%{row | vault_entry_id: entry.id, lifetime_kind: "until"}, "e"},
            {%{row | via_label: "default", lifetime_kind: "once", expires_at: DateTime.utc_now()},
             "f"}
          ] do
        assert :refused = raw_insert(%{bad | binding_key: "k|@ingress|" <> key})
      end

      assert :ok = raw_insert(%{row | via_label: "default", binding_digest: nil})
      assert :ok = raw_insert(%{row | binding_key: "k|x|default", vault_entry_id: entry.id})

      assert :ok = raw_insert(%{row | binding_key: "k|y|default", share_id: "shr_x"})
    end

    test "a pinned and an unpinned selection each write a via row", %{athanor: athanor} do
      profile = profile!(athanor, "prof_vias")

      assert {:ok, _} =
               ConsentStorage.insert_revision(
                 consent_attrs(athanor, profile.id, 1),
                 [
                   %{
                     binding_key: "reagent:local.storage-test|reagent:local.pinned|default",
                     via_label: "default",
                     binding_digest: "sha256:pinned"
                   },
                   %{
                     binding_key: "reagent:local.storage-test|reagent:local.unpinned|default",
                     via_label: "default"
                   }
                 ],
                 nil
               )

      {:ok, head} = ConsentStorage.head_consent(actor(athanor), profile.id)

      assert [pinned, unpinned] = Enum.sort_by(head.vault_refs, & &1.binding_key)

      # A selection is resolved within the borrowing consent's own athanor.
      assert %{
               scope: "athanor",
               via_label: "default",
               binding_digest: "sha256:pinned",
               vault_entry_id: nil
             } = pinned

      assert %{scope: "athanor", via_label: "default", binding_digest: nil, share_id: nil} =
               unpinned

      # A selection's row names no entry: the reverse lookups never see it.
      assert {:ok, []} = ConsentStorage.head_referenced_entries(actor(athanor))
    end

    test "the reverse lookups answer the athanor's entries, by head", %{athanor: athanor} do
      profile = profile!(athanor, "prof_reverse")
      entry = entry!(athanor)

      {:ok, _} =
        ConsentStorage.insert_revision(
          consent_attrs(athanor, profile.id, 1),
          [
            ref(entry.id),
            ref(nil, %{
              binding_key: "reagent:local.storage-test|reagent:local.via|default",
              via_label: "default",
              binding_digest: nil
            })
          ],
          nil
        )

      assert {:ok, [entry_id]} = ConsentStorage.head_referenced_entries(actor(athanor))
      assert entry_id == entry.id

      assert {:ok, [profile_id]} =
               ConsentStorage.head_profiles_referencing(actor(athanor), entry.id)

      assert profile_id == profile.id
    end
  end

  describe "entry_uses/1" do
    # A profile of `source` under `label`, in `status`, whose first
    # revision binds `refs`.
    defp using!(athanor, id, source, label, refs, status \\ "active") do
      {:ok, _profile} =
        Writers.put_profile(%{
          id: id,
          athanor_id: athanor,
          source_ref: source,
          kind: "owner",
          label: label,
          status: "active"
        })

      {:ok, consent} = ConsentStorage.insert_revision(consent_attrs(athanor, id, 1), refs, nil)

      if status != "active",
        do: :ok = ProfileStorage.transition(actor(athanor), id, :any, status)

      consent
    end

    defp used(entry_id, profile_id, source, label),
      do: %{entry_id: entry_id, profile_id: profile_id, source_ref: source, label: label}

    test "`entry_uses/1` names the active heads binding each entry", %{athanor: athanor} do
      [first, second] = Enum.sort_by([entry!(athanor), entry!(athanor)], & &1.id)
      dropped = entry!(athanor)

      # One head binding `first` under two keys, and a selection, which
      # names no entry.
      using!(athanor, "prof_uses_a", "catalyst:local.grok", "default", [
        ref(first.id),
        ref(first.id, %{binding_key: @second_key}),
        ref(nil, %{
          binding_key: "reagent:local.storage-test|reagent:local.via|default",
          via_label: "default",
          binding_digest: nil
        })
      ])

      using!(athanor, "prof_uses_b", "catalyst:local.grok", "work", [ref(first.id)])
      using!(athanor, "prof_uses_c", "reagent:local.other", "default", [ref(second.id)])

      # A head that no longer binds what an earlier revision did.
      earlier =
        using!(athanor, "prof_uses_d", "reagent:local.moved", "default", [ref(dropped.id)])

      {:ok, _} =
        ConsentStorage.insert_revision(
          consent_attrs(athanor, "prof_uses_d", 2),
          [ref(second.id)],
          earlier.id
        )

      # A profile with no head binds nothing.
      _headless = profile!(athanor, "prof_uses_e")

      assert ConsentStorage.entry_uses(actor(athanor)) ==
               {:ok,
                Enum.sort_by(
                  [
                    used(first.id, "prof_uses_a", "catalyst:local.grok", "default"),
                    used(first.id, "prof_uses_b", "catalyst:local.grok", "work"),
                    used(second.id, "prof_uses_c", "reagent:local.other", "default"),
                    used(second.id, "prof_uses_d", "reagent:local.moved", "default")
                  ],
                  &{&1.entry_id, &1.source_ref, &1.label, &1.profile_id}
                )}
    end

    test "a revoked profile's head is not a use", %{athanor: athanor} do
      entry = entry!(athanor)
      using!(athanor, "prof_uses_live", "reagent:local.live", "default", [ref(entry.id)])

      using!(
        athanor,
        "prof_uses_revoked",
        "reagent:local.revoked",
        "default",
        [ref(entry.id)],
        "revoked"
      )

      using!(
        athanor,
        "prof_uses_waiting",
        "reagent:local.waiting",
        "default",
        [ref(entry.id)],
        "needs_consent"
      )

      assert ConsentStorage.entry_uses(actor(athanor)) ==
               {:ok, [used(entry.id, "prof_uses_live", "reagent:local.live", "default")]}
    end

    test "another athanor's heads are never read", %{athanor: athanor} do
      other = Arca.Test.Actor.athanor!("ath_other").id
      mine = entry!(athanor)
      theirs = entry!(other)
      using!(athanor, "prof_uses_mine", "reagent:local.mine", "default", [ref(mine.id)])
      using!(other, "prof_uses_theirs", "reagent:local.theirs", "default", [ref(theirs.id)])

      assert ConsentStorage.entry_uses(actor(athanor)) ==
               {:ok, [used(mine.id, "prof_uses_mine", "reagent:local.mine", "default")]}

      assert ConsentStorage.entry_uses(actor(other)) ==
               {:ok, [used(theirs.id, "prof_uses_theirs", "reagent:local.theirs", "default")]}

      # An actor with no athanor is refused before any query.
      test = self()
      handler = "entry-uses-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          fn _event, _measurements, _meta, _config ->
            if self() == test, do: send(test, :queried)
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      for nobody <- [%Prima.Actor{}, %Prima.Actor{athanor_id: ""}] do
        assert {:error, :no_athanor} = ConsentStorage.entry_uses(nobody)
      end

      :telemetry.detach(handler)
      refute_received :queried
    end
  end

  describe "consume_once/5" do
    setup %{athanor: athanor} do
      profile = profile!(athanor, "prof_once_#{System.unique_integer([:positive])}")
      entry = entry!(athanor)

      {:ok, consent} =
        ConsentStorage.insert_revision(
          consent_attrs(athanor, profile.id, 1),
          [
            ref(entry.id, %{lifetime_kind: "once"}),
            ref(entry.id, %{binding_key: @second_key, lifetime_kind: "once"}),
            ref(entry.id, %{binding_key: @standing_key})
          ],
          nil
        )

      {:ok, profile: profile, entry: entry, consent: consent}
    end

    test "the same root consuming twice under the head is admitted, another root refused",
         %{athanor: athanor, profile: profile, consent: consent} do
      assert :ok =
               ConsentStorage.consume_once(actor(athanor), profile.id, consent.id, @key, "exec_a")

      assert :ok =
               ConsentStorage.consume_once(actor(athanor), profile.id, consent.id, @key, "exec_a")

      assert {:error, :already_consumed} =
               ConsentStorage.consume_once(actor(athanor), profile.id, consent.id, @key, "exec_b")

      assert consumed(athanor, consent.id) == %{@key => "exec_a", @second_key => nil}
    end

    test "two rows of one consent with one entry and different lifetimes are consumed apart",
         %{athanor: athanor, profile: profile, consent: consent} do
      assert :ok =
               ConsentStorage.consume_once(actor(athanor), profile.id, consent.id, @key, "exec_a")

      # The other `once` row of the same entry is its own binding.
      assert :ok =
               ConsentStorage.consume_once(
                 actor(athanor),
                 profile.id,
                 consent.id,
                 @second_key,
                 "exec_b"
               )

      assert consumed(athanor, consent.id) == %{@key => "exec_a", @second_key => "exec_b"}

      assert {:error, :not_once} =
               ConsentStorage.consume_once(
                 actor(athanor),
                 profile.id,
                 consent.id,
                 @standing_key,
                 "exec_a"
               )

      assert {:error, :not_found} =
               ConsentStorage.consume_once(
                 actor(athanor),
                 profile.id,
                 consent.id,
                 "nowhere|@ingress|default",
                 "exec_a"
               )
    end

    test "a pin that is not the head is superseded, consumed before or not",
         %{athanor: athanor, profile: profile, consent: a} do
      assert :ok = ConsentStorage.consume_once(actor(athanor), profile.id, a.id, @key, "exec_a")
      {:ok, head} = ConsentStorage.head_consent(actor(athanor), profile.id)

      {:ok, b} =
        ConsentStorage.insert_revision(
          consent_attrs(athanor, profile.id, 2),
          head.vault_refs,
          a.id
        )

      # Pinned to A after B is the head, having consumed under A: refused,
      # and B's copied row names the root so no other root consumes it.
      assert {:error, :superseded} =
               ConsentStorage.consume_once(actor(athanor), profile.id, a.id, @key, "exec_a")

      assert consumed(athanor, b.id)[@key] == "exec_a"

      assert {:error, :already_consumed} =
               ConsentStorage.consume_once(actor(athanor), profile.id, b.id, @key, "exec_c")

      # Not having consumed under A: refused, and B's row stays unconsumed
      # for a root admitted under B.
      assert {:error, :superseded} =
               ConsentStorage.consume_once(
                 actor(athanor),
                 profile.id,
                 a.id,
                 @second_key,
                 "exec_d"
               )

      assert consumed(athanor, b.id)[@second_key] == nil

      assert :ok =
               ConsentStorage.consume_once(
                 actor(athanor),
                 profile.id,
                 b.id,
                 @second_key,
                 "exec_e"
               )
    end

    test "a revision that changes another binding keeps the consumed once consumed",
         %{athanor: athanor, profile: profile, consent: a, entry: entry} do
      assert :ok = ConsentStorage.consume_once(actor(athanor), profile.id, a.id, @key, "exec_a")
      other = entry!(athanor)

      {:ok, b} =
        ConsentStorage.insert_revision(
          consent_attrs(athanor, profile.id, 2),
          [
            ref(entry.id, %{lifetime_kind: "once"}),
            ref(other.id, %{binding_key: @second_key, lifetime_kind: "once"}),
            ref(entry.id, %{binding_key: @standing_key})
          ],
          a.id
        )

      assert consumed(athanor, b.id) == %{@key => "exec_a", @second_key => nil}
    end

    test "a revision that marks the binding renew makes it consumable again",
         %{athanor: athanor, profile: profile, consent: a, entry: entry} do
      assert :ok = ConsentStorage.consume_once(actor(athanor), profile.id, a.id, @key, "exec_a")

      {:ok, b} =
        ConsentStorage.insert_revision(
          consent_attrs(athanor, profile.id, 2),
          [
            ref(entry.id, %{lifetime_kind: "once", renew: true}),
            ref(entry.id, %{binding_key: @second_key, lifetime_kind: "once"}),
            ref(entry.id, %{binding_key: @standing_key})
          ],
          a.id
        )

      assert consumed(athanor, b.id)[@key] == nil
      assert :ok = ConsentStorage.consume_once(actor(athanor), profile.id, b.id, @key, "exec_b")
    end

    test "a changed lifetime, entry or kind of row carries no consumption across",
         %{athanor: athanor, profile: profile, consent: a, entry: entry} do
      assert :ok = ConsentStorage.consume_once(actor(athanor), profile.id, a.id, @key, "exec_a")

      assert :ok =
               ConsentStorage.consume_once(
                 actor(athanor),
                 profile.id,
                 a.id,
                 @second_key,
                 "exec_b"
               )

      # The first key is now a selection of the same key, the second names
      # another entry: neither is the binding that was consumed.
      other = entry!(athanor)

      {:ok, b} =
        ConsentStorage.insert_revision(
          consent_attrs(athanor, profile.id, 2),
          [
            %{binding_key: @key, via_label: "default", lifetime_kind: "once"},
            ref(other.id, %{binding_key: @second_key, lifetime_kind: "once"}),
            ref(entry.id, %{binding_key: @standing_key})
          ],
          a.id
        )

      assert consumed(athanor, b.id) == %{@key => nil, @second_key => nil}
    end

    test "two via rows that share nothing carry no consumption across",
         %{athanor: athanor} do
      {:ok, profile} =
        Writers.put_profile(%{
          id: "prof_via_carry",
          athanor_id: athanor,
          source_ref: "reagent:local.via-carry",
          kind: "owner",
          label: "default",
          status: "active"
        })

      via = fn label, digest ->
        %{binding_key: @key, via_label: label, binding_digest: digest, lifetime_kind: "once"}
      end

      {:ok, a} =
        ConsentStorage.insert_revision(
          consent_attrs(athanor, profile.id, 1),
          [via.("default", nil)],
          nil
        )

      assert :ok = ConsentStorage.consume_once(actor(athanor), profile.id, a.id, @key, "exec_a")

      {:ok, b} =
        ConsentStorage.insert_revision(
          consent_attrs(athanor, profile.id, 2),
          [via.("work", nil)],
          a.id
        )

      assert consumed(athanor, b.id) == %{@key => nil}

      # The same selection, the same pin and the same lifetime is the same
      # binding, and stays consumed.
      assert :ok = ConsentStorage.consume_once(actor(athanor), profile.id, b.id, @key, "exec_b")

      {:ok, c} =
        ConsentStorage.insert_revision(
          consent_attrs(athanor, profile.id, 3),
          [via.("work", nil)],
          b.id
        )

      assert consumed(athanor, c.id) == %{@key => "exec_b"}
    end

    test "an actor with no athanor is refused before any query", %{profile: profile, consent: c} do
      assert {:error, :no_athanor} =
               ConsentStorage.consume_once(
                 %Prima.Actor{athanor_id: nil},
                 profile.id,
                 c.id,
                 @key,
                 "exec_a"
               )
    end
  end

  defp actor(athanor), do: Prima.Actor.in_athanor(athanor)

  defp consumed(athanor, consent_id) do
    Arca.Repo.all(
      Ecto.Query.from(r in Arca.Schemas.ConsentVaultRef,
        where:
          r.athanor_id == ^athanor and r.consent_id == ^consent_id and r.lifetime_kind == "once",
        select: {r.binding_key, r.consumed_by_root}
      )
    )
    |> Map.new()
  end

  defp raw_insert(row) do
    Arca.Repo.transaction(fn -> Arca.Repo.insert_all(Arca.Schemas.ConsentVaultRef, [row]) end)
    :ok
  rescue
    _refused in Arca.Repo.Errors.db_errors() -> :refused
  end
end

defmodule Arca.ConsentStorageRaceTest do
  @moduledoc """
  Consumption and replacement on connections of their own: inside the
  sandbox one shared connection would serialize the writers the case is
  about. Each case works in an athanor of its own, purged when it ends.
  """

  use ExUnit.Case, async: false

  require Ecto.Query

  alias Arca.ConsentStorage
  alias Ecto.Adapters.SQL.Sandbox

  @key "reagent:local.race|@ingress|default"

  setup do
    athanor = "ath_once_race_#{System.unique_integer([:positive])}"
    on_exit(fn -> unboxed(fn -> Arca.TenantTables.delete_all_for(actor(athanor)) end) end)
    {:ok, athanor: athanor}
  end

  test "two roots racing for one once binding: one is admitted", %{athanor: athanor} do
    for round <- 1..5 do
      {profile, consent} = granted!(athanor, round)

      results =
        for root <- ["exec_a#{round}", "exec_b#{round}"] do
          Task.async(fn ->
            unboxed(fn ->
              ConsentStorage.consume_once(actor(athanor), profile, consent, @key, root)
            end)
          end)
        end
        |> Task.await_many(30_000)

      assert Enum.sort(results) == [:ok, {:error, :already_consumed}]
    end
  end

  test "a root consuming under A while a commit replaces it with B: one order or the other",
       %{athanor: athanor} do
    for round <- 1..5 do
      {profile, a} = granted!(athanor, round)
      root = "exec_root#{round}"

      consume =
        Task.async(fn ->
          unboxed(fn -> ConsentStorage.consume_once(actor(athanor), profile, a, @key, root) end)
        end)

      replace =
        Task.async(fn ->
          unboxed(fn ->
            {:ok, head} = ConsentStorage.head_consent(actor(athanor), profile)

            ConsentStorage.insert_revision(
              attrs(athanor, profile, 2),
              head.vault_refs,
              a
            )
          end)
        end)

      consumed = Task.await(consume, 30_000)
      {:ok, b} = Task.await(replace, 30_000)

      b_root =
        unboxed(fn ->
          Arca.Repo.one(
            Ecto.Query.from(r in Arca.Schemas.ConsentVaultRef,
              where: r.athanor_id == ^athanor and r.consent_id == ^b.id,
              select: r.consumed_by_root
            )
          )
        end)

      # Never an A consumption beside an unconsumed B row: either the
      # copy saw the consumption, or the consumption was refused.
      case consumed do
        :ok -> assert b_root == root
        {:error, :superseded} -> assert b_root == nil
      end
    end
  end

  defp granted!(athanor, round) do
    unboxed(fn ->
      profile = "prof_race_#{round}_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Arca.Test.Writers.put_profile(%{
          id: profile,
          athanor_id: athanor,
          source_ref: "reagent:local.race-#{profile}",
          kind: "owner",
          label: "default",
          status: "active"
        })

      {:ok, entry} =
        Arca.VaultStorage.put(actor(athanor), %{
          name: "entry-#{System.unique_integer([:positive])}",
          kind: "api_key",
          sealed_payload: "sealed",
          destination: ~s({"hosts":["api.example.com"],"scheme":"https"})
        })

      {:ok, consent} =
        ConsentStorage.insert_revision(
          attrs(athanor, profile, 1),
          [
            %{
              binding_key: @key,
              vault_entry_id: entry.id,
              binding_digest: "sha256:b",
              lifetime_kind: "once"
            }
          ],
          nil
        )

      {profile, consent.id}
    end)
  end

  defp attrs(athanor, profile, revision) do
    %{
      athanor_id: athanor,
      profile_id: profile,
      revision: revision,
      scope: "versionless",
      pinned_version: "",
      invoke_mode: "open_inert",
      shape_digest: "sha256:shape",
      commit_digest: "sha256:commit",
      blob_digest: Prima.Digest.sha256("{}"),
      resolved_policy: "{}",
      activation: "{}",
      admitted_origins: [:interactive],
      granted_by: "test",
      granted_via: "bootstrap"
    }
  end

  defp actor(athanor), do: Prima.Actor.in_athanor(athanor)
  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
end
