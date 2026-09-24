# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.StorageProjectionChangesTest do
  @moduledoc """
  The pending changes of a seeded root's units: stamped by the writer that
  makes them, marked ready only by the writer whose change still stands,
  acknowledged only by a replacement made against exactly the generations
  it read — so a unit deleted and recreated, a finisher a later commit
  overtook and an acknowledgment older than the row are each refused, and
  no acknowledgment is ever lowered.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.StorageProjectionChange
  alias Arca.{StorageProjectionChanges, StorageProjectionRoots, StorageUnits}

  @root "components"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    base = Path.join(System.tmp_dir!(), "projection_changes_#{System.unique_integer([:positive])}")
    prev_base = Application.fetch_env!(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, prev_base)
      File.rm_rf!(base)
    end)

    athanor = "ath_changes_#{System.unique_integer([:positive])}"
    key = "catalysts/local/unit-#{System.unique_integer([:positive])}/1.0.0"
    {:ok, actor: %Cyfr.Actor{athanor_id: athanor, user_id: "usr_changes"}, key: key}
  end

  defp identity(revision) do
    %{
      new_revision: revision,
      content_identity: Cyfr.Digest.sha256(revision),
      commit_identity: "usr_changes"
    }
  end

  # A commit's row half, answering the generation it stamped.
  defp commit!(actor, key, revision) do
    token = StorageUnits.new_writer_token()
    {:ok, draft} = StorageUnits.register_draft(actor, @root, key, token)

    {:committed, generation} =
      StorageUnits.stamped_commit(actor, draft, draft.current_revision, token, identity(revision))

    generation
  end

  defp row(actor, key) do
    Arca.Repo.one(
      from(c in StorageProjectionChange,
        where: c.athanor_id == ^actor.athanor_id and c.root == @root and c.unit_key == ^key
      )
    )
  end

  defp standing(actor) do
    {:ok, standing} = StorageProjectionRoots.epoch(actor, @root)
    standing
  end

  defp snapshot(actor, opts \\ []) do
    {:ok, token} = StorageProjectionChanges.snapshot(actor, @root, opts)
    token
  end

  defp acknowledge(actor, token),
    do: StorageProjectionChanges.replace(actor, @root, token, fn -> :acknowledged end)

  describe "a publication" do
    test "is pending until its move finishes, then ready at the generation its commit stamped",
         %{actor: actor, key: key} do
      generation = commit!(actor, key, "rev_1")

      assert %{generation: ^generation, ready: false, source_revision: "rev_1", tombstone: false} =
               row(actor, key)

      assert %{epoch: ^generation, acknowledged_epoch: 0} = standing(actor)

      assert :ok = StorageProjectionChanges.mark_ready(actor, @root, key, generation, "rev_1")
      assert %{generation: ^generation, ready: true} = row(actor, key)
    end

    test "an obsolete finisher cannot mark its successor ready", %{actor: actor, key: key} do
      first = commit!(actor, key, "rev_1")
      second = commit!(actor, key, "rev_2")
      assert second > first

      # The first commit's move finishes after the second commit landed.
      assert {:error, :stale_generation} =
               StorageProjectionChanges.mark_ready(actor, @root, key, first, "rev_1")

      assert %{generation: ^second, ready: false, source_revision: "rev_2"} = row(actor, key)

      # A mark naming the right generation and the wrong revision is refused too.
      assert {:error, :stale_generation} =
               StorageProjectionChanges.mark_ready(actor, @root, key, second, "rev_1")

      assert :ok = StorageProjectionChanges.mark_ready(actor, @root, key, second, "rev_2")
      assert %{generation: ^second, ready: true} = row(actor, key)
    end

    test "a pending change is neither acknowledged nor lets the root's epoch be", %{
      actor: actor,
      key: key
    } do
      ready_key = "catalysts/local/other-#{System.unique_integer([:positive])}/1.0.0"
      ready = commit!(actor, ready_key, "rev_ready")
      :ok = StorageProjectionChanges.mark_ready(actor, @root, ready_key, ready, "rev_ready")
      pending = commit!(actor, key, "rev_pending")

      token = snapshot(actor)
      refute StorageProjectionChanges.complete?(token)
      assert {:ok, :acknowledged} = acknowledge(actor, token)

      assert %{acknowledged_generation: ^ready} = row(actor, ready_key)
      assert %{acknowledged_generation: 0, generation: ^pending} = row(actor, key)
      assert %{epoch: ^pending, acknowledged_epoch: 0} = standing(actor)
    end
  end

  describe "generations" do
    test "strictly increase across retire, draft and commit; a draft stamps nothing", %{
      actor: actor,
      key: key
    } do
      published = commit!(actor, key, "rev_1")

      assert {:retired, deleted} = StorageUnits.stamped_retire(actor, @root, key)
      assert deleted > published
      assert %{generation: ^deleted, tombstone: true, ready: false, source_revision: nil} = row(actor, key)

      {:ok, draft} = StorageUnits.register_draft(actor, @root, key, "wrt_again")
      assert :ok = StorageUnits.abandon_draft(actor, draft, "wrt_again")
      assert %{epoch: ^deleted} = standing(actor)

      recreated = commit!(actor, key, "rev_1")
      assert recreated > deleted
      assert %{generation: ^recreated, tombstone: false, source_revision: "rev_1"} = row(actor, key)
    end

    test "a retirement leaves its tombstone even where no unit row stood", %{actor: actor, key: key} do
      assert {:not_found, generation} = StorageUnits.stamped_retire(actor, @root, key)
      assert {:error, :not_found} = StorageUnits.retire(actor, @root, key)

      assert %{tombstone: true, ready: false} = row(actor, key)
      assert row(actor, key).generation > generation

      assert :ok = StorageProjectionChanges.mark_ready(actor, @root, key, row(actor, key).generation, nil)
      assert %{tombstone: true, ready: true} = row(actor, key)
    end

    test "a tombstone ABA: a token read before a delete and a recreation acknowledges nothing", %{
      actor: actor,
      key: key
    } do
      live = commit!(actor, key, "rev_1")
      :ok = StorageProjectionChanges.mark_ready(actor, @root, key, live, "rev_1")
      before = snapshot(actor)

      # Deleted and recreated at the very revision name the token saw.
      {:retired, deleted} = StorageUnits.stamped_retire(actor, @root, key)
      :ok = StorageProjectionChanges.mark_ready(actor, @root, key, deleted, nil)
      again = commit!(actor, key, "rev_1")
      :ok = StorageProjectionChanges.mark_ready(actor, @root, key, again, "rev_1")

      assert %{source_revision: "rev_1", tombstone: false, ready: true} = row(actor, key)
      assert {:error, :generation_conflict} = acknowledge(actor, before)
      assert %{acknowledged_generation: 0} = row(actor, key)

      # Even a token that saw the epoch as it is now, but the unit at the
      # tombstone, is refused: the unit's generation moved.
      stale_unit =
        before
        |> Map.put(:epoch, standing(actor).epoch)
        |> Map.put(:units, [%{hd(before.units) | generation: deleted}])

      assert {:error, :generation_conflict} = acknowledge(actor, stale_unit)
      assert {:ok, :acknowledged} = acknowledge(actor, snapshot(actor))
      assert %{acknowledged_generation: ^again} = row(actor, key)
    end

    test "a stale acknowledgment never lowers what was acknowledged", %{actor: actor, key: key} do
      first = commit!(actor, key, "rev_1")
      :ok = StorageProjectionChanges.mark_ready(actor, @root, key, first, "rev_1")
      old = snapshot(actor)

      second = commit!(actor, key, "rev_2")
      :ok = StorageProjectionChanges.mark_ready(actor, @root, key, second, "rev_2")
      assert {:ok, :acknowledged} = acknowledge(actor, snapshot(actor))
      assert %{acknowledged_generation: ^second} = row(actor, key)
      assert %{acknowledged_epoch: ^second} = standing(actor)

      assert {:error, :generation_conflict} = acknowledge(actor, old)
      assert %{acknowledged_generation: ^second} = row(actor, key)
      assert %{acknowledged_epoch: ^second} = standing(actor)

      # Acknowledging the same generations again changes nothing.
      assert {:ok, :acknowledged} = acknowledge(actor, snapshot(actor, units: [key]))
      assert %{acknowledged_generation: ^second} = row(actor, key)
    end
  end

  describe "an edit" do
    test "is pending before its write and ready at a newer generation after it", %{
      actor: actor,
      key: key
    } do
      committed = commit!(actor, key, "rev_1")
      {:ok, pending} = StorageProjectionChanges.begin_edit(actor, @root, key)
      assert pending > committed
      assert %{generation: ^pending, ready: false, source_revision: "rev_1"} = row(actor, key)

      {:ok, ready} = StorageProjectionChanges.finish_edit(actor, @root, key, pending)
      assert ready > pending
      assert %{generation: ^ready, ready: true} = row(actor, key)
    end

    test "whose unit another writer has made pending leaves it to that writer", %{
      actor: actor,
      key: key
    } do
      {:ok, mine} = StorageProjectionChanges.begin_edit(actor, @root, key)
      {:ok, theirs} = StorageProjectionChanges.begin_edit(actor, @root, key)

      assert {:ok, :covered} = StorageProjectionChanges.finish_edit(actor, @root, key, mine)
      assert %{generation: ^theirs, ready: false} = row(actor, key)

      {:ok, ready} = StorageProjectionChanges.finish_edit(actor, @root, key, theirs)
      assert %{generation: ^ready, ready: true} = row(actor, key)

      # A writer that returns after another's ready mark takes a newer one:
      # what was derived before its write landed is derived again.
      {:ok, late} = StorageProjectionChanges.finish_edit(actor, @root, key, mine)
      assert late > ready
    end
  end

  describe "settle_stale/3" do
    test "marks a stale edit ready where it stands, and leaves a fresh one", %{
      actor: actor,
      key: key
    } do
      fresh_key = "catalysts/local/fresh-#{System.unique_integer([:positive])}/1.0.0"
      {:ok, stale} = StorageProjectionChanges.begin_edit(actor, @root, key)
      Arca.Repo.update_all(from(c in StorageProjectionChange, where: c.unit_key == ^key),
        set: [updated_at: DateTime.add(DateTime.utc_now(), -120, :second)]
      )

      {:ok, fresh} = StorageProjectionChanges.begin_edit(actor, @root, fresh_key)

      assert {:ok, 1} =
               StorageProjectionChanges.settle_stale(actor, @root, settle_after_ms: 60_000)

      assert %{generation: ^stale, ready: true} = row(actor, key)
      assert %{generation: ^fresh, ready: false} = row(actor, fresh_key)
    end

    test "a publication settled under its finisher is raised to a newer generation by its mark",
         %{actor: actor, key: key} do
      generation = commit!(actor, key, "rev_1")

      # Nothing is staged for rev_1 in this tree, so the settle finds no
      # move to finish and settles the row where it stands.
      assert {:ok, 1} =
               StorageProjectionChanges.settle_stale(actor, @root,
                 settle_after_ms: 0,
                 now: DateTime.add(DateTime.utc_now(), 1, :second)
               )

      assert %{generation: ^generation, ready: true} = row(actor, key)

      assert :ok = StorageProjectionChanges.mark_ready(actor, @root, key, generation, "rev_1")
      assert %{ready: true} = raised = row(actor, key)
      assert raised.generation > generation
    end
  end

  describe "recovery and retention" do
    test "pending_athanors/2 names an estate behind its epoch, to a platform-scope actor alone",
         %{actor: actor, key: key} do
      generation = commit!(actor, key, "rev_1")
      platform = %Cyfr.Actor{scope: :platform, system: true}

      assert {:ok, behind} = StorageProjectionChanges.pending_athanors(platform, limit: 100_000)
      assert actor.athanor_id in behind

      assert {:error, :forbidden} = StorageProjectionChanges.pending_athanors(actor)

      :ok = StorageProjectionChanges.mark_ready(actor, @root, key, generation, "rev_1")
      assert {:ok, :acknowledged} = acknowledge(actor, snapshot(actor))

      assert {:ok, caught_up} = StorageProjectionChanges.pending_athanors(platform, limit: 100_000)
      refute actor.athanor_id in caught_up
    end

    test "prune_acknowledged_tombstones/3 takes only consumed deletion evidence, and the epoch stays",
         %{actor: actor, key: key} do
      other = "catalysts/local/kept-#{System.unique_integer([:positive])}/1.0.0"
      {:not_found, gone} = StorageUnits.stamped_retire(actor, @root, key)
      :ok = StorageProjectionChanges.mark_ready(actor, @root, key, gone, nil)
      {:not_found, _unconsumed} = StorageUnits.stamped_retire(actor, @root, other)

      later = DateTime.add(DateTime.utc_now(), 1, :second)

      # Nothing acknowledged yet: nothing goes.
      assert {:ok, 0} =
               StorageProjectionChanges.prune_acknowledged_tombstones(actor, @root, before: later)

      assert {:ok, :acknowledged} = acknowledge(actor, snapshot(actor))

      assert {:ok, 1} =
               StorageProjectionChanges.prune_acknowledged_tombstones(actor, @root, before: later)

      assert row(actor, key) == nil
      assert %{tombstone: true, ready: false} = row(actor, other)

      # The epoch outlives the evidence: the unit recreated takes a newer
      # generation than any it held.
      assert commit!(actor, key, "rev_again") > gone
    end
  end

  describe "refusals" do
    test "an actor without an athanor is refused before any query", %{key: key} do
      for nobody <- [%Cyfr.Actor{athanor_id: nil}, %Cyfr.Actor{athanor_id: ""}] do
        assert {:error, :no_athanor} = StorageProjectionChanges.snapshot(nobody, @root)
        assert {:error, :no_athanor} = StorageProjectionChanges.mark_ready(nobody, @root, key, 1, nil)
        assert {:error, :no_athanor} = StorageProjectionChanges.begin_edit(nobody, @root, key)
        assert {:error, :no_athanor} = StorageProjectionChanges.finish_edit(nobody, @root, key, 1)
        assert {:error, :no_athanor} = StorageProjectionChanges.begin_repair(nobody, @root, key, "r")

        assert {:error, :no_athanor} =
                 StorageProjectionChanges.settle_stale(nobody, @root, settle_after_ms: 0)

        assert {:error, :no_athanor} =
                 StorageProjectionChanges.prune_acknowledged_tombstones(nobody, @root,
                   before: DateTime.utc_now()
                 )

        assert {:error, :no_athanor} =
                 StorageProjectionChanges.replace(nobody, @root, %{}, fn -> :written end)
      end
    end

    test "a token names its athanor and root, and another's is refused", %{actor: actor, key: key} do
      commit!(actor, key, "rev_1")
      token = snapshot(actor)
      other = %{actor | athanor_id: actor.athanor_id <> "_other"}

      assert {:error, :cross_tenant} =
               StorageProjectionChanges.replace(other, @root, token, fn -> flunk("written") end)

      assert {:error, :invalid_token} =
               StorageProjectionChanges.replace(actor, "aqua", token, fn -> flunk("written") end)

      assert {:error, :invalid_token} =
               StorageProjectionChanges.replace(actor, @root, %{units: []}, fn -> flunk("written") end)

      assert %{acknowledged_epoch: 0} = standing(actor)
    end
  end

  describe "the announcement" do
    setup do
      test = self()
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        StorageProjectionChanges.event(),
        fn _event, measurements, metadata, _config ->
          send(test, {:changed, measurements, metadata, Arca.Repo.in_transaction?()})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "follows each committed change, outside its transaction, and names nothing else", %{
      actor: actor,
      key: key
    } do
      athanor = actor.athanor_id
      generation = commit!(actor, key, "rev_1")

      assert_receive {:changed, %{epoch: ^generation},
                      %{athanor_id: ^athanor, root: @root, ready: false} = metadata, false}

      assert map_size(metadata) == 3

      :ok = StorageProjectionChanges.mark_ready(actor, @root, key, generation, "rev_1")
      assert_receive {:changed, %{epoch: ^generation}, %{ready: true}, false}

      # A commit that is refused commits nothing and announces nothing.
      {:ok, draft} = StorageUnits.register_draft(actor, @root, key, "wrt_late")

      assert {:error, :stale_revision} =
               StorageUnits.stamped_commit(actor, draft, "rev_gone", "wrt_late", identity("rev_2"))

      refute_receive {:changed, _, _, _}, 100
    end
  end
end
