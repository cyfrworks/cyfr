# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.TenantTablesTest do
  @moduledoc """
  `Arca.TenantTables.delete_all_for/1` removes every row an athanor owns
  from the tables its writers fill, and no other athanor's. Each case
  writes its rows through the table's own writer, purges one athanor and
  reads both back.

  The roster's drift against the live schema is
  `apps/cyfr/test/arca/schema_baseline_test.exs`'s.
  """

  # Takes a member slot by writing its lease row; the slot is the case's own.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.FencedPublication
  alias Arca.FencedPublication.Change
  alias Arca.Schemas.{CellLease, FencedDocument, FencedDocumentFloor, StorageStaging}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  test "an athanor's fenced documents, their staging and its revision floor go with it" do
    slot = slot!()
    [purged, kept] = for _ <- 1..2, do: actor()

    for actor <- [purged, kept] do
      assert {:ok, 1} = publish(actor, "kept.md", 0, slot)
      assert {:ok, 1} = publish(actor, "gone.md", 0, slot)
      assert {:ok, 2} = publish(actor, "gone.md", 1, slot)
      assert :ok = FencedPublication.remove(removal(actor, "gone.md"), 2, slot)
      assert %{documents: 1, floor: [2]} = rows(actor)
    end

    assert {:ok, counts} = Arca.TenantTables.delete_all_for(purged)
    assert counts["fenced_documents"] == 1
    assert counts["fenced_document_floors"] == 1
    assert counts["storage_staging"] == 3

    assert %{documents: 0, staging: 0, floor: []} = rows(purged)
    assert %{documents: 1, staging: 3, floor: [2]} = rows(kept)
  end

  # ---- helpers ---------------------------------------------------------------

  defp actor,
    do: Arca.Test.Actor.local(athanor_id: "ath_tt_#{System.unique_integer([:positive])}")

  defp publish(actor, key, revision_read, slot) do
    {:ok, staged} = Arca.Storage.stage(actor, "attempt-#{System.unique_integer()}", key)

    FencedPublication.publish(
      %Change{resource: {:document, actor.athanor_id, key}, staged: staged},
      revision_read,
      slot
    )
  end

  defp removal(actor, key), do: %Change{resource: {:document, actor.athanor_id, key}}

  defp rows(%Prima.Actor{athanor_id: athanor_id}) do
    %{
      documents:
        Arca.Repo.aggregate(from(d in FencedDocument, where: d.athanor_id == ^athanor_id), :count),
      staging:
        Arca.Repo.aggregate(from(s in StorageStaging, where: s.athanor_id == ^athanor_id), :count),
      floor:
        Arca.Repo.all(
          from(f in FencedDocumentFloor, where: f.athanor_id == ^athanor_id, select: f.floor)
        )
    }
  end

  # A member slot of this case's own, written straight to its row.
  defp slot! do
    node = "node-tt-#{System.unique_integer([:positive])}"
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
