# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ConsentStorageTest do
  use ExUnit.Case, async: false

  alias Arca.ConsentStorage
  alias Arca.ProfileStorage
  alias Arca.VaultStorage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()
    {:ok, athanor: ctx.athanor_id}
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
      VaultStorage.put(%{
        athanor_id: athanor,
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
      resolved_policy: "{}",
      activation: "{}",
      granted_by: "test",
      granted_via: "bootstrap"
    }
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

      {:ok, head, refs} = ConsentStorage.get_head(athanor, profile.id)
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

      assert {:error, :no_head} = ConsentStorage.get_head(athanor, profile.id)
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

      {:ok, head, _refs} = ConsentStorage.get_head(athanor, profile.id)
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

      assert {:error, :no_head} = ConsentStorage.get_head(athanor, profile.id)
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

      {:ok, profile} = ProfileStorage.get(athanor, "prof_mint_1")
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

      assert {:error, :not_found} = ProfileStorage.get(athanor, "prof_mint_2")
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
