# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ProfileStorageTest do
  @moduledoc """
  The profile table holds one active profile per identity: the second is
  refused by the schema's active-identity index, through the changeset's
  mapping, never raised. A source's live profiles are revoked together, in
  the actor's athanor alone. A status moves only as the profile table of
  `Arca.StatusTransitions` admits, in one conditional write: a revoked
  profile never comes back, and a write of the status a row already holds
  succeeds wherever the table lists it. The rows are written through
  `Arca.Test.Writers.put_profile/1`.
  """
  use ExUnit.Case, async: false

  alias Arca.ProfileStorage
  alias Arca.Test.Writers

  @source_ref "reagent:local.profile-storage-test"

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    {:ok, athanor: Arca.Test.Actor.athanor_id()}
  end

  defp attrs(athanor, over) do
    Map.merge(
      %{
        athanor_id: athanor,
        source_ref: @source_ref,
        kind: "owner",
        label: "default",
        status: "active"
      },
      over
    )
  end

  describe "the active-identity index" do
    test "a second active profile on the same identity refuses instead of raising", %{
      athanor: athanor
    } do
      assert {:ok, _} = Writers.put_profile(attrs(athanor, %{label: "work"}))
      assert {:error, {:invalid, errors}} = Writers.put_profile(attrs(athanor, %{label: "work"}))
      assert map_size(errors) > 0
    end
  end

  describe "revoke_for_source/2" do
    test "revokes the source's live profiles in the actor's athanor, and answers them", %{
      athanor: athanor
    } do
      actor = Prima.Actor.in_athanor(athanor)
      {:ok, owner} = Writers.put_profile(attrs(athanor, %{}))

      {:ok, blocked} =
        Writers.put_profile(attrs(athanor, %{label: "blocked", status: "needs_consent"}))

      {:ok, _gone} = Writers.put_profile(attrs(athanor, %{label: "gone", status: "revoked"}))

      {:ok, elsewhere} =
        Writers.put_profile(attrs(athanor, %{source_ref: "reagent:local.other-source"}))

      assert {:ok, revoked} = ProfileStorage.revoke_for_source(actor, @source_ref)
      assert Enum.sort(revoked) == Enum.sort([owner.id, blocked.id])

      assert {:ok, []} = ProfileStorage.list_for_source(actor, @source_ref)
      assert {:ok, %{status: "active"}} = ProfileStorage.get(actor, elsewhere.id)
      assert {:ok, []} = ProfileStorage.revoke_for_source(actor, @source_ref)
    end

    test "an actor with no athanor is refused before any query" do
      assert {:error, :no_athanor} = ProfileStorage.revoke_for_source(%Prima.Actor{}, @source_ref)
    end

    @tag :capture_log
    test "a store that cannot answer is a database error", %{athanor: athanor} do
      Arca.Repo.query!("ALTER TABLE profiles RENAME TO profiles_unavailable")

      assert {:error, :database_error} =
               ProfileStorage.revoke_for_source(Prima.Actor.in_athanor(athanor), @source_ref)
    end
  end

  describe "transition/4" do
    test "moves a profile only along the table, and never out of revoked", %{athanor: athanor} do
      actor = Prima.Actor.in_athanor(athanor)

      for {from, to, answer} <- [
            {"active", "needs_consent", :ok},
            {"needs_consent", "needs_consent", :ok},
            {"needs_consent", "active", :ok},
            {"active", "revoked", :ok},
            {"needs_consent", "revoked", :ok},
            {"revoked", "revoked", :ok},
            {"active", "active", {:error, :illegal_transition}},
            {"revoked", "active", {:error, :illegal_transition}},
            {"revoked", "needs_consent", {:error, :illegal_transition}}
          ] do
        profile = profile!(athanor, from)

        assert ProfileStorage.transition(actor, profile.id, from, to) == answer,
               "#{from} -> #{to}"

        held = if answer == :ok, do: to, else: from
        assert {:ok, %{status: ^held}} = ProfileStorage.get(actor, profile.id)
      end
    end

    test "a revoked profile is not reactivated by any source the caller names", %{
      athanor: athanor
    } do
      actor = Prima.Actor.in_athanor(athanor)
      profile = profile!(athanor, "revoked")

      for from <- [:any, "revoked", ["needs_consent", "revoked"], ["active"], []] do
        assert {:error, :illegal_transition} =
                 ProfileStorage.transition(actor, profile.id, from, "active")
      end

      assert {:ok, %{status: "revoked"}} = ProfileStorage.get(actor, profile.id)
    end

    test "writes only while the row holds a status the caller named", %{athanor: athanor} do
      actor = Prima.Actor.in_athanor(athanor)
      profile = profile!(athanor, "needs_consent")

      # Revoked by another writer after the caller read it active.
      assert :ok = ProfileStorage.transition(actor, profile.id, :any, "revoked")

      assert {:error, :illegal_transition} =
               ProfileStorage.transition(actor, profile.id, "active", "needs_consent")

      assert {:ok, %{status: "revoked"}} = ProfileStorage.get(actor, profile.id)
    end

    test "an unknown status, another athanor's row and a missing row change nothing", %{
      athanor: athanor
    } do
      actor = Prima.Actor.in_athanor(athanor)
      profile = profile!(athanor, "active")
      other = Prima.Actor.in_athanor("#{athanor}_other")

      assert {:error, :illegal_transition} =
               ProfileStorage.transition(actor, profile.id, "active", "bogus")

      assert {:error, :not_found} =
               ProfileStorage.transition(other, profile.id, "active", "revoked")

      assert {:error, :not_found} =
               ProfileStorage.transition(actor, "prof_missing", "active", "revoked")

      assert {:error, :no_athanor} =
               ProfileStorage.transition(%Prima.Actor{}, profile.id, "active", "revoked")

      assert {:ok, %{status: "active"}} = ProfileStorage.get(actor, profile.id)
    end

    @tag :capture_log
    test "a store that cannot answer is a database error", %{athanor: athanor} do
      Arca.Repo.query!("ALTER TABLE profiles RENAME TO profiles_unavailable")

      assert {:error, :database_error} =
               ProfileStorage.transition(
                 Prima.Actor.in_athanor(athanor),
                 "prof_any",
                 :any,
                 "revoked"
               )
    end
  end

  defp profile!(athanor, status) do
    {:ok, profile} =
      Writers.put_profile(
        attrs(athanor, %{
          id: "prof_#{System.unique_integer([:positive])}",
          label: "l#{System.unique_integer([:positive])}",
          status: status
        })
      )

    profile
  end
end
