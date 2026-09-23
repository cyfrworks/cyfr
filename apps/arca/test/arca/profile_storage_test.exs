# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ProfileStorageTest do
  @moduledoc """
  The profile insert is held to the profile vocabulary by the schema's
  changeset — the label grammar above all, since `RootSelect.decode/1`
  tells an id from a label by the `prof_` prefix and is only sound while
  no stored label wears it.
  """
  use ExUnit.Case, async: false

  alias Arca.ProfileStorage

  @source_ref "reagent:local.profile-storage-test"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
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

  describe "put/1" do
    test "an id-shaped or empty label is refused typed, and no row lands", %{athanor: athanor} do
      assert {:error, {:invalid_label, "prof_sneaky"}} =
               ProfileStorage.put(attrs(athanor, %{label: "prof_sneaky"}))

      assert {:error, {:invalid_label, ""}} = ProfileStorage.put(attrs(athanor, %{label: ""}))

      assert {:ok, []} =
               ProfileStorage.list_for_source(Cyfr.Actor.in_athanor(athanor), @source_ref)
    end

    test "a label merely carrying the prefix's letters is stored", %{athanor: athanor} do
      assert {:ok, %{label: "prof-hyphen", id: "prof_" <> _}} =
               ProfileStorage.put(attrs(athanor, %{label: "prof-hyphen"}))
    end

    test "kind and status are held to the profile vocabulary", %{athanor: athanor} do
      assert {:error, {:invalid, errors}} =
               ProfileStorage.put(attrs(athanor, %{kind: "guest"}))

      assert Map.has_key?(errors, :kind)

      assert {:error, {:invalid, errors}} =
               ProfileStorage.put(attrs(athanor, %{status: "sleeping"}))

      assert Map.has_key?(errors, :status)
    end

    test "a second active profile on the same identity refuses instead of raising", %{
      athanor: athanor
    } do
      assert {:ok, _} = ProfileStorage.put(attrs(athanor, %{label: "work"}))
      assert {:error, {:invalid, errors}} = ProfileStorage.put(attrs(athanor, %{label: "work"}))
      assert map_size(errors) > 0
    end
  end

  describe "revoke_for_source/2" do
    test "revokes the source's live profiles in the actor's athanor, and answers them", %{
      athanor: athanor
    } do
      actor = Cyfr.Actor.in_athanor(athanor)
      {:ok, owner} = ProfileStorage.put(attrs(athanor, %{}))
      {:ok, blocked} = ProfileStorage.put(attrs(athanor, %{label: "blocked", status: "needs_consent"}))
      {:ok, _gone} = ProfileStorage.put(attrs(athanor, %{label: "gone", status: "revoked"}))

      {:ok, elsewhere} =
        ProfileStorage.put(attrs(athanor, %{source_ref: "reagent:local.other-source"}))

      assert {:ok, revoked} = ProfileStorage.revoke_for_source(actor, @source_ref)
      assert Enum.sort(revoked) == Enum.sort([owner.id, blocked.id])

      assert {:ok, []} = ProfileStorage.list_for_source(actor, @source_ref)
      assert {:ok, %{status: "active"}} = ProfileStorage.get(actor, elsewhere.id)
      assert {:ok, []} = ProfileStorage.revoke_for_source(actor, @source_ref)
    end

    test "an actor with no athanor is refused before any query" do
      assert {:error, :no_athanor} = ProfileStorage.revoke_for_source(%Cyfr.Actor{}, @source_ref)
    end

    @tag :capture_log
    test "a store that cannot answer is a database error", %{athanor: athanor} do
      Arca.Repo.query!("ALTER TABLE profiles RENAME TO profiles_unavailable")

      assert {:error, :database_error} =
               ProfileStorage.revoke_for_source(Cyfr.Actor.in_athanor(athanor), @source_ref)
    end
  end
end
