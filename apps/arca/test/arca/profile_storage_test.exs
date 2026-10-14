# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ProfileStorageTest do
  @moduledoc """
  The profile table holds one active profile per identity: the second is
  refused by the schema's active-identity index, through the changeset's
  mapping, never raised. A source's live profiles are revoked together, in
  the actor's athanor alone. The rows are written through
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
end
