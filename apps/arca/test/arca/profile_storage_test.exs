# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ProfileStorageTest do
  @moduledoc """
  The profile table holds one active profile per identity: the second is
  refused by the schema's active-identity index, through the changeset's
  mapping, never raised. A source's live profiles are revoked together, in
  the actor's athanor alone, as a removal's, and a profile already revoked
  keeps its cause. A person's revocation is written by its own verb and
  names the person. A status moves only as the profile table of
  `Arca.StatusTransitions` admits, in one conditional write: a revoked
  profile never comes back, a `needs_consent` profile written so again
  succeeds, `active → active` is refused, since `active` comes only by
  re-consent, and no status write revokes, since a revocation names its
  cause. The rows are written through `Arca.Test.Writers.put_profile/1`.
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

      {:ok, gone} =
        Writers.put_profile(
          attrs(athanor, %{label: "gone", status: "revoked", revoked_by: "person"})
        )

      {:ok, elsewhere} =
        Writers.put_profile(attrs(athanor, %{source_ref: "reagent:local.other-source"}))

      assert {:ok, revoked} = ProfileStorage.revoke_for_source(actor, @source_ref)
      assert Enum.sort(revoked) == Enum.sort([owner.id, blocked.id])

      assert {:ok, []} = ProfileStorage.list_for_source(actor, @source_ref)
      assert {:ok, %{status: "active"}} = ProfileStorage.get(actor, elsewhere.id)
      assert {:ok, []} = ProfileStorage.revoke_for_source(actor, @source_ref)

      # The removal is the cause of what it revoked; the person's own
      # revocation before it keeps theirs.
      for id <- [owner.id, blocked.id],
          do: assert({:ok, %{revoked_by: "removal"}} = ProfileStorage.get(actor, id))

      assert {:ok, %{status: "revoked", revoked_by: "person"}} =
               ProfileStorage.get(actor, gone.id)
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
            {"active", "revoked", {:error, :illegal_transition}},
            {"needs_consent", "revoked", {:error, :illegal_transition}},
            {"revoked", "revoked", {:error, :illegal_transition}},
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
      assert :ok = ProfileStorage.revoke_by_person(actor, profile.id)

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
               ProfileStorage.transition(other, profile.id, "active", "needs_consent")

      assert {:error, :not_found} =
               ProfileStorage.transition(actor, "prof_missing", "active", "needs_consent")

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
                 "needs_consent"
               )
    end
  end

  describe "revoke_by_person/2" do
    test "revokes from any status, naming the person, a removal's revocation among them", %{
      athanor: athanor
    } do
      actor = Prima.Actor.in_athanor(athanor)

      for status <- ["active", "needs_consent", "revoked"] do
        profile = profile!(athanor, status)
        assert :ok = ProfileStorage.revoke_by_person(actor, profile.id), status

        assert {:ok, %{status: "revoked", revoked_by: "person"}} =
                 ProfileStorage.get(actor, profile.id)
      end
    end

    test "another athanor's row, a missing row and no athanor change nothing", %{
      athanor: athanor
    } do
      actor = Prima.Actor.in_athanor(athanor)
      profile = profile!(athanor, "active")

      assert {:error, :not_found} =
               ProfileStorage.revoke_by_person(
                 Prima.Actor.in_athanor("#{athanor}_other"),
                 profile.id
               )

      assert {:error, :not_found} = ProfileStorage.revoke_by_person(actor, "prof_missing")
      assert {:error, :no_athanor} = ProfileStorage.revoke_by_person(%Prima.Actor{}, profile.id)
      assert {:ok, %{status: "active", revoked_by: nil}} = ProfileStorage.get(actor, profile.id)
    end
  end

  describe "a revocation's cause" do
    test "is held to the row by the changeset: a revoked row names one, no other row any", %{
      athanor: athanor
    } do
      assert {:error, {:invalid, %{revoked_by: _}}} =
               Writers.put_profile(attrs(athanor, %{label: "a", status: "revoked"}))

      assert {:error, {:invalid, %{revoked_by: _}}} =
               Writers.put_profile(
                 attrs(athanor, %{label: "b", status: "revoked", revoked_by: "bogus"})
               )

      assert {:error, {:invalid, %{revoked_by: _}}} =
               Writers.put_profile(attrs(athanor, %{label: "c", revoked_by: "person"}))
    end
  end

  defp profile!(athanor, status) do
    {:ok, profile} =
      Writers.put_profile(
        attrs(athanor, %{
          id: "prof_#{System.unique_integer([:positive])}",
          label: "l#{System.unique_integer([:positive])}",
          status: status,
          revoked_by: if(status == "revoked", do: "removal")
        })
      )

    profile
  end
end
