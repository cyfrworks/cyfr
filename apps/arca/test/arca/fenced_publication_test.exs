# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.FencedPublicationTest do
  @moduledoc """
  `Arca.FencedPublication.publish/3` keeps three facts apart and checks
  each: the revision the writer read (a conflict is `:stale`, never a
  comparison of generations), the writer's live ownership of its slot on
  the database's clock (`:not_owner`, whether the lease was taken over or
  merely ran out), and never the lease row's renewal fence. Idempotency is
  by resource, revision and content together. A removed document's
  revision is never reused in its athanor: a document created again
  stands above every revision it held.

  Every case names its own member slot and athanor, so what it measures
  is its own.
  """

  # Takes and renews a slot through `Arca.ControlPlane`, which writes the
  # process-wide standing record; each case saves and restores it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ControlPlane
  alias Arca.FencedPublication
  alias Arca.FencedPublication.Change
  alias Arca.Schemas.{CellLease, RetentionSettings, StorageStaging}

  @keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    saved = Map.new(@keys, &{&1, :persistent_term.get(&1, :absent)})

    on_exit(fn ->
      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end
    end)

    {:ok, actor: actor(), key: "doc-#{System.unique_integer([:positive])}"}
  end

  describe "ownership" do
    test "a lease that ran out with no successor is refused as a takeover is", %{
      actor: actor,
      key: key
    } do
      slot = slot!()
      staged = stage!(actor, "v1")
      expire!(slot)

      assert {:error, :not_owner} =
               FencedPublication.publish(document(actor, key, staged), 0, slot)

      assert :not_found = FencedPublication.document(actor, key)
      assert %StorageStaging{state: "reserved"} = staging(staged)
    end

    test "a takeover before the publication is refused, and the successor publishes", %{
      actor: actor,
      key: key
    } do
      slot = slot!()
      staged = stage!(actor, "v1")
      successor = take_over!(slot)

      assert {:error, :not_owner} =
               FencedPublication.publish(document(actor, key, staged), 0, slot)

      assert {:ok, 1} = FencedPublication.publish(document(actor, key, staged), 0, successor)
    end

    test "an ordinary renewal between the read and the publication still publishes", %{
      actor: actor,
      key: key
    } do
      node = "node-fp-#{System.unique_integer([:positive])}"
      assert {:ok, slot} = ControlPlane.take(node, node <> "#boot_a", 60_000)
      staged = stage!(actor, "v1")

      # The writer reads the document, and the claimant renews while it writes.
      assert :not_found = FencedPublication.document(actor, key)
      assert {:ok, renewed} = ControlPlane.renew(60_000)
      assert renewed.fence > slot.fence

      # The slot the writer carries still names the fence it read; the
      # fence is the renewal's token and no part of the publication.
      assert {:ok, 1} = FencedPublication.publish(document(actor, key, staged), 0, slot)
      assert {:ok, %{fence: fence}} = ControlPlane.slot(node)
      assert fence == renewed.fence
    end

    test "another owner or another generation of the slot is refused", %{actor: actor, key: key} do
      slot = slot!()
      staged = stage!(actor, "v1")
      change = document(actor, key, staged)

      assert {:error, :not_owner} = FencedPublication.publish(change, 0, %{slot | owner: "other"})

      assert {:error, :not_owner} =
               FencedPublication.publish(change, 0, %{slot | generation: slot.generation + 1})

      assert {:ok, 1} = FencedPublication.publish(change, 0, slot)
    end
  end

  describe "the resource revision" do
    test "two healthy members writing one document: the second is :stale whatever its generation",
         %{actor: actor, key: key} do
      low = slot!(generation: 1)
      high = slot!(generation: 7)
      first = stage!(actor, "from low")
      second = stage!(actor, "from high")

      # Both read revision 0. The lower generation lands first, and the
      # higher one loses on the revision, not on its generation.
      assert {:ok, 1} = FencedPublication.publish(document(actor, key, first), 0, low)
      assert {:error, :stale} = FencedPublication.publish(document(actor, key, second), 0, high)

      # Read again, the loser publishes over the revision it now read.
      assert {:ok, 2} = FencedPublication.publish(document(actor, key, second), 1, high)
      assert %{revision: 2, blob_key: blob_key} = FencedPublication.document(actor, key)
      assert blob_key == "staging/" <> second
    end

    test "two healthy members writing one row: the second is :stale", %{actor: actor} do
      low = slot!(generation: 1)
      high = slot!(generation: 3)
      settings!(actor, 1)
      resource = {:row, RetentionSettings, actor.athanor_id}

      assert {:ok, 2} =
               FencedPublication.publish(
                 %Change{resource: resource, attrs: %{settings: ~s({"a":1})}},
                 1,
                 high
               )

      assert {:error, :stale} =
               FencedPublication.publish(
                 %Change{resource: resource, attrs: %{settings: ~s({"b":2})}},
                 1,
                 low
               )

      assert %RetentionSettings{revision: 2, settings: ~s({"a":1})} =
               Arca.Repo.get!(RetentionSettings, actor.athanor_id)
    end

    test "a document read as absent is created at revision 1; a later absent read is :stale", %{
      actor: actor,
      key: key
    } do
      slot = slot!()
      first = stage!(actor, "v1")
      second = stage!(actor, "v2")

      assert {:ok, 1} = FencedPublication.publish(document(actor, key, first), 0, slot)
      assert {:error, :stale} = FencedPublication.publish(document(actor, key, second), 0, slot)
      assert {:error, :stale} = FencedPublication.publish(document(actor, key, second), 4, slot)

      assert %{revision: 1, digest: digest} = FencedPublication.document(actor, key)
      assert digest == Prima.Digest.sha256("v1")

      # The losing attempt is still reserved, and publishes once read again.
      assert %StorageStaging{state: "reserved"} = staging(second)
      assert {:ok, 2} = FencedPublication.publish(document(actor, key, second), 1, slot)
    end
  end

  describe "a removed revision is never reused" do
    test "a writer holding a removed document's revision does not publish over it created again",
         %{actor: actor, key: key} do
      slot = slot!()

      assert {:ok, 1} =
               FencedPublication.publish(document(actor, key, stage!(actor, "v1")), 0, slot)

      assert :ok = FencedPublication.remove(removal(actor, key), 1, slot)

      again = stage!(actor, "again")
      assert {:ok, created} = FencedPublication.publish(document(actor, key, again), 0, slot)

      # A writer that read revision 1 before the removal publishes now.
      stale = stage!(actor, "stale")
      assert {:error, :stale} = FencedPublication.publish(document(actor, key, stale), 1, slot)

      assert created == 2
      assert %{revision: 2, blob_key: blob_key} = FencedPublication.document(actor, key)
      assert blob_key == "staging/" <> again
      assert %StorageStaging{state: "reserved"} = staging(stale)
    end

    test "a removal holding the old incarnation's revision is :stale against the new one", %{
      actor: actor,
      key: key
    } do
      slot = slot!()

      assert {:ok, 1} =
               FencedPublication.publish(document(actor, key, stage!(actor, "v1")), 0, slot)

      assert :ok = FencedPublication.remove(removal(actor, key), 1, slot)

      again = stage!(actor, "again")
      assert {:ok, created} = FencedPublication.publish(document(actor, key, again), 0, slot)

      assert {:error, :stale} = FencedPublication.remove(removal(actor, key), 1, slot)
      assert created == 2
      assert %{revision: 2} = FencedPublication.document(actor, key)
      assert %StorageStaging{state: "published"} = staging(again)
    end

    test "an exact create retry after a removal answers the revision it created, and writes nothing",
         %{actor: actor, key: key} do
      slot = slot!()

      for {bytes, revision_read} <- [{"v1", 0}, {"v2", 1}, {"v3", 2}] do
        assert {:ok, _} =
                 FencedPublication.publish(
                   document(actor, key, stage!(actor, bytes)),
                   revision_read,
                   slot
                 )
      end

      assert :ok = FencedPublication.remove(removal(actor, key), 3, slot)

      change = document(actor, key, stage!(actor, "again"))
      assert {:ok, 4} = FencedPublication.publish(change, 0, slot)
      assert {:ok, 4} = FencedPublication.publish(change, 0, slot)

      assert {:ok, 4} =
               FencedPublication.publish(
                 %{change | digest: Prima.Digest.sha256("again")},
                 0,
                 slot
               )

      # Another attempt's identical bytes are no replay of this one.
      other = stage!(actor, "again")
      assert {:error, :stale} = FencedPublication.publish(document(actor, key, other), 0, slot)
      assert {:error, :stale} = FencedPublication.publish(change, 4, slot)
      assert %{revision: 4} = FencedPublication.document(actor, key)
      assert floor_of(actor) == 3
    end

    test "the floor is the highest revision removed, and a create takes one above it", %{
      actor: actor
    } do
      slot = slot!()
      prefix = "floor-#{System.unique_integer([:positive])}/"

      # Documents never removed are created at 1, and creating raises nothing.
      for name <- ["a", "b"] do
        assert {:ok, 1} =
                 FencedPublication.publish(
                   document(actor, prefix <> name, stage!(actor, name)),
                   0,
                   slot
                 )
      end

      assert floor_of(actor) == 0

      # Updates count from the document's own revision.
      for revision_read <- 1..3 do
        assert {:ok, revision} =
                 FencedPublication.publish(
                   document(actor, prefix <> "a", stage!(actor, "a#{revision_read}")),
                   revision_read,
                   slot
                 )

        assert revision == revision_read + 1
      end

      # A removal raises the floor to the revision removed, and never lowers it.
      assert :ok = FencedPublication.remove(removal(actor, prefix <> "a"), 4, slot)
      assert :ok = FencedPublication.remove(removal(actor, prefix <> "b"), 1, slot)
      assert floor_of(actor) == 4

      # Every create of the athanor now starts above it, the names removed
      # and a name never used alike.
      for name <- ["b", "c"] do
        assert {:ok, 5} =
                 FencedPublication.publish(
                   document(actor, prefix <> name, stage!(actor, name <> "2")),
                   0,
                   slot
                 )
      end

      assert floor_of(actor) == 4

      # Another athanor's floor is its own.
      other = actor("ath_fp_floor_other_#{System.unique_integer([:positive])}")

      assert {:ok, 1} =
               FencedPublication.publish(
                 document(other, prefix <> "a", stage!(other, "o")),
                 0,
                 slot
               )
    end

    test "a refused create or removal leaves the floor as it was", %{actor: actor, key: key} do
      slot = slot!()

      assert {:ok, 1} =
               FencedPublication.publish(document(actor, key, stage!(actor, "v1")), 0, slot)

      assert floor_of(actor) == 0

      # A create that lost to the document already there, and a removal of
      # a revision it no longer holds, roll back what they wrote.
      assert {:error, :stale} =
               FencedPublication.publish(document(actor, key, stage!(actor, "late")), 0, slot)

      assert {:error, :stale} = FencedPublication.remove(removal(actor, key), 7, slot)
      assert floor_of(actor) == 0

      successor = take_over!(slot)
      assert {:error, :not_owner} = FencedPublication.remove(removal(actor, key), 1, slot)
      assert floor_of(actor) == 0
      assert :ok = FencedPublication.remove(removal(actor, key), 1, successor)
      assert floor_of(actor) == 1
    end
  end

  describe "idempotency" do
    test "a staged blob published twice is a no-op at the same revision and :stale at another", %{
      actor: actor,
      key: key
    } do
      slot = slot!()
      staged = stage!(actor, "v1")
      change = document(actor, key, staged)

      assert {:ok, 1} = FencedPublication.publish(change, 0, slot)
      assert {:ok, 1} = FencedPublication.publish(change, 0, slot)

      assert {:ok, 1} =
               FencedPublication.publish(%{change | digest: Prima.Digest.sha256("v1")}, 0, slot)

      assert {:error, :stale} = FencedPublication.publish(change, 1, slot)
      assert {:error, :stale} = FencedPublication.publish(change, 5, slot)
      assert %{revision: 1} = FencedPublication.document(actor, key)
      assert %StorageStaging{state: "published"} = staging(staged)
    end

    test "two writers staging identical content each publish against their own revision", %{
      actor: actor,
      key: key
    } do
      slot = slot!()
      first = stage!(actor, "same bytes")
      second = stage!(actor, "same bytes")

      assert first != second
      assert staging(first).digest == staging(second).digest
      assert staging(first).key != staging(second).key

      assert {:ok, 1} = FencedPublication.publish(document(actor, key, first), 0, slot)
      # The same bytes, but another attempt's: not a replay of the first.
      assert {:error, :stale} = FencedPublication.publish(document(actor, key, second), 0, slot)
      assert {:ok, 2} = FencedPublication.publish(document(actor, key, second), 1, slot)
      assert %{revision: 2, blob_key: blob_key} = FencedPublication.document(actor, key)
      assert blob_key == "staging/" <> second
    end

    test "a row publication replayed with the same attrs is a no-op, with others :stale", %{
      actor: actor
    } do
      slot = slot!()
      settings!(actor, 3)
      resource = {:row, RetentionSettings, actor.athanor_id}
      change = %Change{resource: resource, attrs: %{settings: ~s({"a":1})}}

      assert {:ok, 4} = FencedPublication.publish(change, 3, slot)
      assert {:ok, 4} = FencedPublication.publish(change, 3, slot)

      assert {:error, :stale} =
               FencedPublication.publish(%{change | attrs: %{settings: ~s({"b":1})}}, 3, slot)

      assert {:error, :stale} = FencedPublication.publish(change, 2, slot)
      assert %RetentionSettings{revision: 4} = Arca.Repo.get!(RetentionSettings, actor.athanor_id)
    end

    test "a row that does not exist is :stale", %{actor: actor} do
      slot = slot!()
      change = %Change{resource: {:row, RetentionSettings, actor.athanor_id}, attrs: %{}}

      assert {:error, :stale} = FencedPublication.publish(change, 0, slot)
    end
  end

  describe "the staged attempt" do
    test "an attempt whose reservation ran out, or was cancelled, is refused :expired", %{
      actor: actor,
      key: key
    } do
      slot = slot!()
      expired = stage!(actor, "late")
      cancelled = stage!(actor, "withdrawn")
      expire_staging!(expired)
      assert :ok = Arca.Storage.cancel_stage(actor, cancelled)

      assert {:error, :expired} =
               FencedPublication.publish(document(actor, key, expired), 0, slot)

      assert {:error, :expired} =
               FencedPublication.publish(document(actor, key, cancelled), 0, slot)

      assert :not_found = FencedPublication.document(actor, key)
    end

    test "a publication after the sweep's claim is refused :expired", %{actor: actor, key: key} do
      slot = slot!()
      staged = stage!(actor, "v1")

      {1, _} =
        Arca.Repo.update_all(from(s in StorageStaging, where: s.id == ^staged),
          set: [state: "deleting"]
        )

      assert {:error, :expired} = FencedPublication.publish(document(actor, key, staged), 0, slot)
    end

    test "an attempt reclaimed by the sweep, or never staged, is refused :expired", %{
      actor: actor,
      key: key
    } do
      slot = slot!()
      staged = stage!(actor, "v1")
      expire_staging!(staged)
      assert {:ok, 1} = Arca.Retention.FencedStaging.prune(actor, 1, false)

      assert {:error, :expired} = FencedPublication.publish(document(actor, key, staged), 0, slot)

      assert {:error, :expired} =
               FencedPublication.publish(
                 document(actor, key, "01NEVERSTAGED0000000000000"),
                 0,
                 slot
               )
    end

    test "a digest other than the one recorded is refused :expired", %{actor: actor, key: key} do
      slot = slot!()
      staged = stage!(actor, "v1")
      change = %{document(actor, key, staged) | digest: Prima.Digest.sha256("v2")}

      assert {:error, :expired} = FencedPublication.publish(change, 0, slot)
      assert %StorageStaging{state: "reserved"} = staging(staged)
    end

    test "another athanor's attempt is refused :expired, and the document stays absent", %{
      actor: actor,
      key: key
    } do
      slot = slot!()
      theirs = stage!(actor("ath_fp_theirs_#{System.unique_integer([:positive])}"), "theirs")

      assert {:error, :expired} = FencedPublication.publish(document(actor, key, theirs), 0, slot)
      assert :not_found = FencedPublication.document(actor, key)
      assert %StorageStaging{state: "reserved"} = staging(theirs)
    end

    test "an attempt whose bytes were never recorded is refused :expired", %{
      actor: actor,
      key: key
    } do
      slot = slot!()
      staged = stage!(actor, "v1")

      {1, _} =
        Arca.Repo.update_all(from(s in StorageStaging, where: s.id == ^staged),
          set: [digest: nil]
        )

      assert {:error, :expired} = FencedPublication.publish(document(actor, key, staged), 0, slot)
    end
  end

  describe "the change's shape" do
    test "a change of no known shape raises before any statement", %{actor: actor, key: key} do
      slot = slot!()
      staged = stage!(actor, "v1")

      for change <- [
            %Change{resource: {:document, actor.athanor_id, key}},
            %Change{resource: {:document, actor.athanor_id, key}, staged: staged, attrs: %{a: 1}},
            %Change{resource: {:row, RetentionSettings, actor.athanor_id}, staged: staged},
            %Change{resource: {:row, RetentionSettings, actor.athanor_id}, attrs: %{revision: 9}},
            %Change{resource: {:row, RetentionSettings, actor.athanor_id}, attrs: %{"a" => 1}},
            %Change{resource: {:elsewhere, key}}
          ] do
        assert_raise ArgumentError, fn -> FencedPublication.publish(change, 0, slot) end
      end
    end
  end

  describe "document/2" do
    test "reads the actor's athanor only, and refuses an actor with none", %{
      actor: actor,
      key: key
    } do
      slot = slot!()
      staged = stage!(actor, "v1")
      assert {:ok, 1} = FencedPublication.publish(document(actor, key, staged), 0, slot)

      assert %{athanor_id: athanor, key: ^key, revision: 1, blob_key: blob_key, digest: digest} =
               FencedPublication.document(actor, key)

      assert athanor == actor.athanor_id
      assert digest == Prima.Digest.sha256("v1")
      assert {:ok, "v1"} = Arca.get(actor, String.split(blob_key, "/"))

      assert :not_found = FencedPublication.document(actor("ath_fp_other"), key)
      assert {:error, :no_athanor} = FencedPublication.document(%{actor | athanor_id: ""}, key)
    end
  end

  describe "no slot" do
    test "publishes and removes, with the revision still compared, only where no claimant runs",
         %{actor: actor, key: key} do
      claimed(false)
      staged = stage!(actor, "v1")
      assert {:ok, 1} = FencedPublication.publish(document(actor, key, staged), 0, :none)
      assert {:error, :stale} = FencedPublication.publish(document(actor, key, staged), 3, :none)
      assert {:error, :stale} = FencedPublication.remove(removal(actor, key), 0, :none)

      claimed(true)
      again = stage!(actor, "v2")

      assert {:error, :not_owner} =
               FencedPublication.publish(document(actor, key, again), 1, :none)

      assert {:error, :not_owner} = FencedPublication.remove(removal(actor, key), 1, :none)

      assert %{revision: 1, digest: digest} = FencedPublication.document(actor, key)
      assert digest == Prima.Digest.sha256("v1")
      assert %StorageStaging{state: "reserved"} = staging(again)
    end

    test "a slot of no known shape raises before any statement", %{actor: actor, key: key} do
      staged = stage!(actor, "v1")

      assert_raise ArgumentError, fn ->
        FencedPublication.publish(document(actor, key, staged), 0, :someone)
      end
    end
  end

  describe "list/2" do
    test "the actor's documents under a prefix, ordered by key, and no one else's", %{
      actor: actor
    } do
      slot = slot!()
      prefix = "list-#{System.unique_integer([:positive])}/"

      for key <- ["b.md", "a.md", "deeper/c.md"] do
        staged = stage!(actor, key)

        assert {:ok, 1} =
                 FencedPublication.publish(document(actor, prefix <> key, staged), 0, slot)
      end

      # A key that only shares the prefix's letters, a pattern character
      # and another athanor's document are not listed.
      staged = stage!(actor, "near")
      near = String.trim_trailing(prefix, "/") <> "-near/x.md"
      assert {:ok, 1} = FencedPublication.publish(document(actor, near, staged), 0, slot)
      other = actor("ath_fp_list_other_#{System.unique_integer([:positive])}")
      theirs = stage!(other, "theirs")

      assert {:ok, 1} =
               FencedPublication.publish(document(other, prefix <> "a.md", theirs), 0, slot)

      assert {:ok, docs} = FencedPublication.list(actor, prefix)

      assert Enum.map(docs, & &1.key) ==
               Enum.map(["a.md", "b.md", "deeper/c.md"], &(prefix <> &1))

      assert Enum.all?(docs, &(&1.athanor_id == actor.athanor_id and &1.revision == 1))

      assert {:ok, []} = FencedPublication.list(actor, "list-%/")
      assert {:ok, []} = FencedPublication.list(actor, String.upcase(prefix))
      assert {:error, :no_athanor} = FencedPublication.list(%{actor | athanor_id: ""}, prefix)
    end
  end

  describe "remove/3" do
    test "removes the document at the revision read and hands its bytes to the sweep", %{
      actor: actor,
      key: key
    } do
      slot = slot!()
      first = stage!(actor, "v1")
      second = stage!(actor, "v2")
      assert {:ok, 1} = FencedPublication.publish(document(actor, key, first), 0, slot)
      assert {:ok, 2} = FencedPublication.publish(document(actor, key, second), 1, slot)

      assert {:error, :stale} = FencedPublication.remove(removal(actor, key), 1, slot)
      assert %{revision: 2} = FencedPublication.document(actor, key)
      assert %StorageStaging{state: "published"} = staging(second)

      assert :ok = FencedPublication.remove(removal(actor, key), 2, slot)
      assert :not_found = FencedPublication.document(actor, key)
      assert %StorageStaging{state: "deleting"} = staging(second)

      # Removed is absent: nothing to remove again, and a publication that
      # read it absent creates it anew, above every revision it held.
      assert {:error, :stale} = FencedPublication.remove(removal(actor, key), 2, slot)
      third = stage!(actor, "v3")
      assert {:ok, 3} = FencedPublication.publish(document(actor, key, third), 0, slot)
    end

    test "a slot taken over, or run out, removes nothing", %{actor: actor, key: key} do
      slot = slot!()
      staged = stage!(actor, "v1")
      assert {:ok, 1} = FencedPublication.publish(document(actor, key, staged), 0, slot)

      successor = take_over!(slot)
      assert {:error, :not_owner} = FencedPublication.remove(removal(actor, key), 1, slot)
      assert %{revision: 1} = FencedPublication.document(actor, key)
      assert %StorageStaging{state: "published"} = staging(staged)

      expire!(successor)
      assert {:error, :not_owner} = FencedPublication.remove(removal(actor, key), 1, successor)
      assert %{revision: 1} = FencedPublication.document(actor, key)
    end

    test "a removal of no known shape raises before any statement", %{actor: actor, key: key} do
      slot = slot!()
      staged = stage!(actor, "v1")

      for change <- [
            document(actor, key, staged),
            %Change{resource: {:document, actor.athanor_id, key}, attrs: %{a: 1}},
            %Change{resource: {:row, RetentionSettings, actor.athanor_id}}
          ] do
        assert_raise ArgumentError, fn -> FencedPublication.remove(change, 1, slot) end
      end
    end
  end

  describe "the budget" do
    test "stays under the lease margin" do
      assert FencedPublication.budget_ms() < ControlPlane.margin_ms()
    end
  end

  # ---- helpers ---------------------------------------------------------------

  defp actor(athanor_id \\ "ath_fp_#{System.unique_integer([:positive])}"),
    do: Arca.Test.Actor.local(athanor_id: athanor_id)

  defp document(actor, key, staged),
    do: %Change{resource: {:document, actor.athanor_id, key}, staged: staged}

  defp removal(actor, key), do: %Change{resource: {:document, actor.athanor_id, key}}

  # The deployment's claimant switch, restored when the case ends.
  defp claimed(enabled) do
    previous = Application.get_env(:arca, :control_plane_claim_enabled)

    ExUnit.Callbacks.on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, previous)
    end)

    Application.put_env(:arca, :control_plane_claim_enabled, enabled)
  end

  defp stage!(actor, bytes) do
    assert {:ok, id} = Arca.Storage.stage(actor, "attempt-#{System.unique_integer()}", bytes)
    id
  end

  defp staging(id), do: Arca.Repo.get!(StorageStaging, id)

  # The athanor's revision floor, read by its table's name.
  defp floor_of(actor) do
    Arca.Repo.one!(
      from(f in "fenced_document_floors",
        where: f.athanor_id == ^actor.athanor_id,
        select: f.floor
      )
    )
  end

  defp expire_staging!(id) do
    past = DateTime.add(Arca.ServerMetaStorage.now!(), -1_000, :millisecond)

    {1, _} =
      Arca.Repo.update_all(from(s in StorageStaging, where: s.id == ^id), set: [expires_at: past])

    :ok
  end

  defp settings!(actor, revision) do
    now = DateTime.utc_now()

    Arca.Repo.insert_all(RetentionSettings, [
      %{
        athanor_id: actor.athanor_id,
        settings: "{}",
        revision: revision,
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  # A member slot of this case's own, written straight to its row: the
  # standing cache belongs to the claimant and is not what is measured.
  defp slot!(opts \\ []) do
    node = "node-fp-#{System.unique_integer([:positive])}"
    generation = Keyword.get(opts, :generation, 1)
    now = Arca.ServerMetaStorage.now!()

    row = %{
      node: node,
      owner: node <> "#boot_a",
      generation: generation,
      fence: 1,
      lease_until: DateTime.add(now, 60_000, :millisecond),
      taken_at: now,
      inserted_at: now,
      updated_at: now
    }

    {1, _} = Arca.Repo.insert_all(CellLease, [row])
    %{node: node, owner: row.owner, generation: generation, fence: 1}
  end

  defp expire!(%{node: node}) do
    past = DateTime.add(Arca.ServerMetaStorage.now!(), -1_000, :millisecond)

    {1, _} =
      Arca.Repo.update_all(from(l in CellLease, where: l.node == ^node), set: [lease_until: past])

    :ok
  end

  defp take_over!(%{node: node, generation: generation, fence: fence}) do
    owner = node <> "#boot_b"

    {1, _} =
      Arca.Repo.update_all(from(l in CellLease, where: l.node == ^node),
        set: [owner: owner, generation: generation + 1, fence: fence + 1]
      )

    %{node: node, owner: owner, generation: generation + 1, fence: fence + 1}
  end
end

defmodule Arca.FencedPublicationFloorRaceTest do
  @moduledoc """
  Two creators of one document removed at a raised floor, racing on
  connections of their own outside the sandbox: both read it absent and
  are held at their publishing statements by a third transaction's
  uncommitted row at the key. Once it rolls back, exactly one creates the
  document one above the revision its removed incarnation held, and the
  other is `:stale`, with the floor left as the removal raised it.

  Both adapters: on PostgreSQL one creator waits on the key and the other
  on the floor row the first holds; on SQLite both wait on the one write
  lock.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.FencedPublication
  alias Arca.FencedPublication.Change
  alias Arca.Schemas.{CellLease, FencedDocument}
  alias Ecto.Adapters.SQL.Sandbox

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  setup do
    actor = Arca.Test.Actor.local(athanor_id: "ath_fpr_#{System.unique_integer([:positive])}")
    node = "node-fpr-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(from(l in CellLease, where: l.node == ^node))
        {:ok, _} = Arca.TenantTables.delete_all_for(actor)
      end)
    end)

    {:ok, actor: actor, node: node, key: "doc-#{System.unique_integer([:positive])}"}
  end

  test "two creators racing: one creates one above the raised floor, the other is :stale", ctx do
    slot = unboxed(fn -> slot!(ctx.node) end)

    # The document held revisions 1 to 3 and was removed at 3.
    unboxed(fn ->
      assert {:ok, 1} = publish(ctx, stage!(ctx.actor, "v1"), 0, slot)
      assert {:ok, 2} = publish(ctx, stage!(ctx.actor, "v2"), 1, slot)
      assert {:ok, 3} = publish(ctx, stage!(ctx.actor, "v3"), 2, slot)
      assert :ok = FencedPublication.remove(removal(ctx), 3, slot)
    end)

    first = unboxed(fn -> stage!(ctx.actor, "first") end)
    second = unboxed(fn -> stage!(ctx.actor, "second") end)

    # A row at the key, never committed: each creator's insert waits on it.
    holder =
      holding(fn ->
        now = Arca.ServerMetaStorage.now!()

        Arca.Repo.insert_all(FencedDocument, [
          %{
            athanor_id: ctx.actor.athanor_id,
            key: ctx.key,
            revision: 99,
            blob_key: "held",
            digest: "held",
            inserted_at: now,
            updated_at: now
          }
        ])
      end)

    creators =
      for staged <- [first, second],
          do: Task.async(fn -> unboxed(fn -> publish(ctx, staged, 0, slot) end) end)

    assert Enum.all?(Task.yield_many(creators, 300), &match?({_, nil}, &1)),
           "a create passed a key another transaction held"

    assert {:error, :released} = release(holder)
    results = Enum.map(creators, &Task.await(&1, 25_000))

    assert Enum.sort(results) == [{:error, :stale}, {:ok, 4}]

    assert {:ok, [%FencedDocument{revision: 4, blob_key: blob_key}]} =
             unboxed(fn ->
               {:ok,
                Arca.Repo.all(
                  from(d in FencedDocument,
                    where: d.athanor_id == ^ctx.actor.athanor_id and d.key == ^ctx.key
                  )
                )}
             end)

    winner = if results == [{:ok, 4}, {:error, :stale}], do: first, else: second
    assert blob_key == "staging/" <> winner

    assert [3] =
             unboxed(fn ->
               Arca.Repo.all(
                 from(f in "fenced_document_floors",
                   where: f.athanor_id == ^ctx.actor.athanor_id,
                   select: f.floor
                 )
               )
             end)
  end

  # Run `write` in a transaction of its own, hold it open until
  # `release/1`, then roll it back.
  defp holding(write) do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            write.()
            send(test, {:holding, self()})

            receive do
              :release -> Arca.Repo.rollback(:released)
            end
          end)
        end)
      end)

    assert_receive {:holding, _pid}, 5_000
    task
  end

  defp release(task) do
    send(task.pid, :release)
    Task.await(task, 25_000)
  end

  defp publish(ctx, staged, revision, slot) do
    FencedPublication.publish(
      %Change{resource: {:document, ctx.actor.athanor_id, ctx.key}, staged: staged},
      revision,
      slot
    )
  end

  defp removal(ctx), do: %Change{resource: {:document, ctx.actor.athanor_id, ctx.key}}

  defp stage!(actor, bytes) do
    {:ok, id} = Arca.Storage.stage(actor, "attempt-#{System.unique_integer()}", bytes)
    id
  end

  defp slot!(node) do
    now = Arca.ServerMetaStorage.now!()

    row = %{
      node: node,
      owner: node <> "#boot_a",
      generation: 1,
      fence: 1,
      lease_until: DateTime.add(now, 60_000, :millisecond),
      taken_at: now,
      inserted_at: now,
      updated_at: now
    }

    {1, _} = Arca.Repo.insert_all(CellLease, [row])
    %{node: node, owner: row.owner, generation: 1, fence: 1}
  end
end

defmodule Arca.FencedPublicationLockTest do
  @moduledoc """
  `Arca.FencedPublication.publish/3` under real concurrency, on
  connections of its own outside the sandbox: a takeover that holds the
  lease row while a publication waits on it wins, a publication's shared
  hold on its member's row does not make the member's next publication
  wait while a writer of the row does, a reservation that runs out while
  a publication waits is refused, the sweep never reclaims an attempt a
  live publication holds, and a publication that outran its budget rolls
  back with the slot left as it was.

  PostgreSQL only: SQLite's one write lock serializes every transaction,
  so there is no wait inside one to observe.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.FencedPublication
  alias Arca.FencedPublication.Change
  alias Arca.Schemas.{CellLease, FencedDocument, StorageStaging}
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :postgres

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  setup do
    athanor = "ath_fpl_#{System.unique_integer([:positive])}"
    node = "node-fpl-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(from(l in CellLease, where: l.node == ^node))
        Arca.Repo.delete_all(from(s in StorageStaging, where: s.athanor_id == ^athanor))
        Arca.Repo.delete_all(from(d in FencedDocument, where: d.athanor_id == ^athanor))
      end)
    end)

    {:ok,
     actor: Arca.Test.Actor.local(athanor_id: athanor),
     node: node,
     key: "doc-#{System.unique_integer([:positive])}"}
  end

  test "a takeover while the publication waits on the lease row is refused", ctx do
    slot = unboxed(fn -> slot!(ctx.node) end)
    staged = unboxed(fn -> stage!(ctx.actor, "v1") end)

    taker =
      holding(fn ->
        Arca.Repo.update_all(from(l in CellLease, where: l.node == ^ctx.node),
          set: [owner: ctx.node <> "#boot_b", generation: slot.generation + 1, fence: 2]
        )
      end)

    publisher = Task.async(fn -> unboxed(fn -> publish(ctx, staged, 0, slot) end) end)
    refute Task.yield(publisher, 300), "the publication passed a lease row a takeover held"

    release(taker)
    assert {:error, :not_owner} = Task.await(publisher, 25_000)
    assert :not_found = unboxed(fn -> FencedPublication.document(ctx.actor, ctx.key) end)
  end

  test "a member's publications share its lease row, and a writer of the row waits for them",
       ctx do
    slot = unboxed(fn -> slot!(ctx.node) end)
    staged = unboxed(fn -> stage!(ctx.actor, "v1") end)

    verifier =
      holding(fn -> Arca.ControlPlane.verify_held(slot) end, &Arca.Repo.locking_transaction/1)

    # Another publication of the same member does not wait behind it.
    assert {:ok, 1} =
             Task.await(
               Task.async(fn -> unboxed(fn -> publish(ctx, staged, 0, slot) end) end),
               5_000
             )

    # The claimant's renew does.
    renewer =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.update_all(from(l in CellLease, where: l.node == ^ctx.node),
            set: [fence: 2]
          )
        end)
      end)

    refute Task.yield(renewer, 300), "a renew wrote a lease row a publication held"
    release(verifier)
    assert {1, _} = Task.await(renewer, 25_000)
  end

  test "a reservation that runs out while the publication waits is refused :expired", ctx do
    slot = unboxed(fn -> slot!(ctx.node) end)
    staged = unboxed(fn -> stage!(ctx.actor, "v1") end)
    unboxed(fn -> expires_in!(staged, 200) end)

    renewer =
      holding(fn ->
        Arca.Repo.update_all(from(l in CellLease, where: l.node == ^ctx.node), set: [fence: 2])
      end)

    publisher = Task.async(fn -> unboxed(fn -> publish(ctx, staged, 0, slot) end) end)
    refute Task.yield(publisher, 400)

    release(renewer)
    assert {:error, :expired} = Task.await(publisher, 25_000)

    # Unpublished and past its reservation: the sweep's to reclaim.
    assert {:ok, 1} =
             unboxed(fn -> Arca.Retention.FencedStaging.prune(ctx.actor, 1, false) end)

    assert nil == unboxed(fn -> Arca.Repo.get(StorageStaging, staged) end)
  end

  test "the sweep never reclaims an attempt a live publication holds", ctx do
    slot = unboxed(fn -> slot!(ctx.node) end)
    first = unboxed(fn -> stage!(ctx.actor, "v1") end)
    assert {:ok, 1} = unboxed(fn -> publish(ctx, first, 0, slot) end)

    second = unboxed(fn -> stage!(ctx.actor, "v2") end)
    unboxed(fn -> expires_in!(second, 300) end)

    # The document row held, so the publication claims the attempt and
    # then waits at its publishing statement.
    holder =
      holding(fn ->
        from(d in FencedDocument,
          where: d.athanor_id == ^ctx.actor.athanor_id and d.key == ^ctx.key
        )
        |> Arca.QueryHelpers.for_update()
        |> Arca.Repo.one()
      end)

    publisher = Task.async(fn -> unboxed(fn -> publish(ctx, second, 1, slot) end) end)
    refute Task.yield(publisher, 500)

    # The attempt has run out on the clock while the publication holds it.
    sweeper =
      Task.async(fn ->
        unboxed(fn -> Arca.Retention.FencedStaging.prune(ctx.actor, 1, false) end)
      end)

    refute Task.yield(sweeper, 300), "the sweep claimed an attempt a publication held"

    release(holder)
    assert {:ok, 2} = Task.await(publisher, 25_000)
    assert {:ok, 0} = Task.await(sweeper, 25_000)

    assert %StorageStaging{state: "published"} =
             unboxed(fn -> Arca.Repo.get!(StorageStaging, second) end)

    assert {:ok, "v2"} = Arca.get(ctx.actor, ["staging", second])
  end

  test "a publication past its budget rolls back and leaves the slot as it was", ctx do
    slot = unboxed(fn -> slot!(ctx.node) end)
    staged = unboxed(fn -> stage!(ctx.actor, "v1") end)
    held = Arca.ControlPlane.held()

    renewer =
      holding(fn ->
        Arca.Repo.update_all(from(l in CellLease, where: l.node == ^ctx.node), set: [fence: 2])
      end)

    publisher = Task.async(fn -> unboxed(fn -> publish(ctx, staged, 0, slot) end) end)
    Process.sleep(FencedPublication.budget_ms() + 200)
    release(renewer)

    assert {:error, :budget} = Task.await(publisher, 25_000)
    assert :not_found = unboxed(fn -> FencedPublication.document(ctx.actor, ctx.key) end)

    assert %StorageStaging{state: "reserved"} =
             unboxed(fn -> Arca.Repo.get!(StorageStaging, staged) end)

    assert %CellLease{owner: owner, generation: generation} =
             unboxed(fn -> Arca.Repo.get!(CellLease, ctx.node) end)

    assert {owner, generation} == {slot.owner, slot.generation}
    assert Arca.ControlPlane.held() == held

    # The slot still holds: the next publication lands.
    assert {:ok, 1} = unboxed(fn -> publish(ctx, staged, 0, slot) end)
  end

  # ---- helpers ---------------------------------------------------------------

  # Run `write` in a transaction of its own and hold it open until
  # `release/1`.
  defp holding(write, transaction \\ &Arca.Repo.transaction/1) do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          transaction.(fn ->
            result = write.()
            send(test, {:holding, self()})

            receive do
              :commit -> result
            end
          end)
        end)
      end)

    assert_receive {:holding, _pid}, 5_000
    task
  end

  defp release(task) do
    send(task.pid, :commit)
    Task.await(task, 25_000)
  end

  defp publish(ctx, staged, revision, slot) do
    FencedPublication.publish(
      %Change{resource: {:document, ctx.actor.athanor_id, ctx.key}, staged: staged},
      revision,
      slot
    )
  end

  defp stage!(actor, bytes) do
    {:ok, id} = Arca.Storage.stage(actor, "attempt", bytes)
    id
  end

  defp expires_in!(id, ms) do
    at = DateTime.add(Arca.ServerMetaStorage.now!(), ms, :millisecond)

    {1, _} =
      Arca.Repo.update_all(from(s in StorageStaging, where: s.id == ^id), set: [expires_at: at])

    :ok
  end

  defp slot!(node) do
    now = Arca.ServerMetaStorage.now!()

    row = %{
      node: node,
      owner: node <> "#boot_a",
      generation: 1,
      fence: 1,
      lease_until: DateTime.add(now, 60_000, :millisecond),
      taken_at: now,
      inserted_at: now,
      updated_at: now
    }

    {1, _} = Arca.Repo.insert_all(CellLease, [row])
    %{node: node, owner: row.owner, generation: 1, fence: 1}
  end
end
