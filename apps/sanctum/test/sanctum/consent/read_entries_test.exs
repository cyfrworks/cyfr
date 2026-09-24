# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.ReadEntriesTest do
  # The consent rows a domain or a surface may learn about, and only
  # through these three entries: scoped by the caller's tenant, with an
  # outage, a damaged row and an absent one kept apart.
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Sanctum.Consent
  alias Sanctum.Test.ConsentFixtures

  @source "reagent:local.read-entries"
  @other_source "reagent:local.read-entries-other"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {ctx, other} = Sanctum.TestContext.two_contexts()
    {:ok, ctx: ctx, other: other}
  end

  defp profile(id, overrides \\ %{}) do
    Map.merge(
      %{id: id, kind: :owner, source_ref: @source, label: "default", status: :active},
      overrides
    )
  end

  defp consent(id) do
    policy = "{}"

    %{
      id: id,
      revision: 1,
      scope: :versionless,
      pinned_version: "",
      invoke_mode: :open_inert,
      shape_digest: "sha256:shape",
      commit_digest: "sha256:commit",
      blob_digest: Prima.JCS.hash_binary(policy),
      resolved_policy: policy,
      activation: %{}
    }
  end

  defp seed!(ctx, id, overrides \\ %{}) do
    :ok = ConsentFixtures.seed_head!(ctx, profile(id, overrides), consent("cons_" <> id))
  end

  # A stored value outside the closed vocabulary, written past every
  # writer's guard — the only way such a row exists.
  defp hand_edit_profile!(ctx, id, changes) do
    {1, _} =
      Arca.Repo.update_all(
        from(p in Arca.Schemas.Profile, where: p.athanor_id == ^ctx.athanor_id and p.id == ^id),
        set: changes
      )
  end

  defp outage!(table), do: Arca.Repo.query!("ALTER TABLE #{table} RENAME TO #{table}_unavailable")

  defp no_tenant(ctx), do: %{ctx | athanor_id: nil}

  describe "profiles/2" do
    test "answers the caller's non-revoked profiles of the source, decoded", %{ctx: ctx} do
      seed!(ctx, "prof_owner")
      seed!(ctx, "prof_public", %{kind: :public, label: "public"})
      seed!(ctx, "prof_gone", %{label: "gone", status: :revoked})
      seed!(ctx, "prof_elsewhere", %{source_ref: @other_source})

      assert {:ok, entries} = Consent.profiles(ctx, @source)

      assert entries |> Enum.map(& &1.id) |> Enum.sort() == ["prof_owner", "prof_public"]
      assert %{kind: :public, status: :active, source_ref: @source} =
               Enum.find(entries, &(&1.id == "prof_public"))
    end

    test "another tenant's profiles are not the caller's", %{ctx: ctx, other: other} do
      seed!(other, "prof_theirs")

      assert {:ok, []} = Consent.profiles(ctx, @source)
      assert {:ok, [%{id: "prof_theirs"}]} = Consent.profiles(other, @source)
    end

    test "a row that cannot be decoded is present, marked corrupt, never dropped", %{ctx: ctx} do
      seed!(ctx, "prof_fine")
      seed!(ctx, "prof_damaged", %{label: "damaged"})
      hand_edit_profile!(ctx, "prof_damaged", kind: "sideways")

      assert {:ok, entries} = Consent.profiles(ctx, @source)
      assert %{id: "prof_damaged", status: :corrupt} in entries
      assert Enum.any?(entries, &match?(%{id: "prof_fine", kind: :owner, status: :active}, &1))

      # The marker carries nothing that could be selected.
      assert Enum.find(entries, &(&1.id == "prof_damaged")) ==
               %{id: "prof_damaged", status: :corrupt}
    end

    @tag :capture_log
    test "a store that cannot answer is unavailable, never an empty list", %{ctx: ctx} do
      seed!(ctx, "prof_owner")
      outage!("profiles")

      assert {:error, :unavailable} = Consent.profiles(ctx, @source)
    end

    test "a context with no tenant is refused before any read", %{ctx: ctx} do
      assert {:error, :no_athanor} = Consent.profiles(no_tenant(ctx), @source)
    end
  end

  describe "head_consent/2" do
    test "answers the profile's head revision, decoded with its vault refs", %{ctx: ctx} do
      seed!(ctx, "prof_owner")

      assert {:ok, head} = Consent.head_consent(ctx, "prof_owner")
      assert %{id: "cons_prof_owner", revision: 1, scope: :versionless, vault_refs: []} = head
      assert head.resolved_policy == "{}"
    end

    test "a profile with no head, an unknown one and another tenant's are all absent",
         %{ctx: ctx, other: other} do
      :ok = ConsentFixtures.seed_profile!(ctx, profile("prof_headless"))
      seed!(other, "prof_theirs")

      assert {:error, :not_found} = Consent.head_consent(ctx, "prof_headless")
      assert {:error, :not_found} = Consent.head_consent(ctx, "prof_nobody")
      assert {:error, :not_found} = Consent.head_consent(ctx, "prof_theirs")
    end

    test "a head holding a value outside the vocabulary is corrupt, not absent", %{ctx: ctx} do
      seed!(ctx, "prof_owner")
      :ok = ConsentFixtures.hand_edit_head!(ctx, "prof_owner", scope: "everywhere")

      assert {:error, :corrupt} = Consent.head_consent(ctx, "prof_owner")
    end

    @tag :capture_log
    test "a store that cannot answer is unavailable, not absent", %{ctx: ctx} do
      seed!(ctx, "prof_owner")
      outage!("consents")

      assert {:error, :unavailable} = Consent.head_consent(ctx, "prof_owner")
    end

    test "a context with no tenant is refused", %{ctx: ctx} do
      assert {:error, :no_athanor} = Consent.head_consent(no_tenant(ctx), "prof_owner")
    end
  end

  describe "revoke_source/2" do
    test "revokes every live profile of the source and keeps their history", %{ctx: ctx} do
      seed!(ctx, "prof_owner")
      seed!(ctx, "prof_public", %{kind: :public, label: "public"})
      seed!(ctx, "prof_blocked", %{label: "blocked", status: :needs_consent})
      seed!(ctx, "prof_elsewhere", %{source_ref: @other_source})

      assert {:ok, %{revoked: revoked}} = Consent.revoke_source(ctx, @source)
      assert Enum.sort(revoked) == ["prof_blocked", "prof_owner", "prof_public"]

      assert {:ok, []} = Consent.profiles(ctx, @source)
      assert {:ok, [%{id: "prof_elsewhere", status: :active}]} = Consent.profiles(ctx, @other_source)

      # Consent history stays: the revoked profile still has its head.
      assert {:ok, %{revision: 1}} = Consent.head_consent(ctx, "prof_owner")

      # Nothing left to revoke.
      assert {:ok, %{revoked: []}} = Consent.revoke_source(ctx, @source)
    end

    test "another tenant's profiles of the same source are untouched",
         %{ctx: ctx, other: other} do
      seed!(other, "prof_theirs")

      assert {:ok, %{revoked: []}} = Consent.revoke_source(ctx, @source)
      assert {:ok, [%{id: "prof_theirs", status: :active}]} = Consent.profiles(other, @source)
    end

    @tag :capture_log
    test "a store that cannot answer is unavailable and revokes nothing", %{ctx: ctx} do
      seed!(ctx, "prof_owner")
      outage!("profiles")

      assert {:error, :unavailable} = Consent.revoke_source(ctx, @source)
    end

    test "a context with no tenant is refused", %{ctx: ctx} do
      assert {:error, :no_athanor} = Consent.revoke_source(no_tenant(ctx), @source)
    end
  end
end
