# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CanvasVersionsTest do
  @moduledoc """
  The versions document of each canvas: published fenced over the revision
  the writer read, read back as the document with its revision and digest,
  one per canvas in the actor's athanor; a publication over a newer
  revision is refused, a member that lost its slot publishes nothing, and
  stored bytes that no longer hold their digest, or that the codec did not
  write, read as corrupt. The codec is the document's canonical JSON with
  absent fields omitted, and refuses anything else.
  """

  # Takes a slot through `Arca.ControlPlane`, which writes the process-wide
  # standing record; each case saves and restores it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.CanvasVersions
  alias Arca.ControlPlane
  alias Arca.Schemas.{CellLease, FencedDocument, StorageStaging}

  @keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    saved = Map.new(@keys, &{&1, :persistent_term.get(&1, :absent)})
    claim = Application.get_env(:arca, :control_plane_claim_enabled)

    on_exit(fn ->
      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end

      if is_nil(claim),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)

    athanor = "ath_cnv_#{System.unique_integer([:positive])}"
    {:ok, actor: Arca.Test.Actor.local(athanor_id: athanor), name: "markets", slot: hold_slot!()}
  end

  # A claimant runs, and this member holds its slot.
  defp hold_slot! do
    Application.put_env(:arca, :control_plane_claim_enabled, true)
    node = "node-cnv-#{System.unique_integer([:positive])}"
    {:ok, slot} = ControlPlane.take(node, node <> "#boot_a", 60_000)
    slot
  end

  defp document(fields \\ %{}), do: Map.merge(CanvasVersions.empty(), fields)

  defp stored_row(actor, name), do: Arca.Repo.one!(row_query(actor, name))

  defp row_query(actor, name) do
    key = CanvasVersions.key(name)
    from(d in FencedDocument, where: d.athanor_id == ^actor.athanor_id and d.key == ^key)
  end

  test "a canvas whose versions were never published is not found", %{actor: actor, name: name} do
    assert {:error, :not_found} = CanvasVersions.get(actor, name)
    assert CanvasVersions.empty() == document()
    assert CanvasVersions.key(name) == "canvases/markets"
  end

  test "a publication reads back as the document, its revision and its digest", %{
    actor: actor,
    name: name
  } do
    allocated = document(%{allocated: "0.1.0"})
    assert {:ok, 1} = CanvasVersions.publish(actor, name, allocated, 0)

    assert {:ok, %{document: ^allocated, revision: 1, digest: digest}} =
             CanvasVersions.get(actor, name)

    # The bytes are the document's canonical JSON, absent fields omitted.
    {:ok, bytes} = CanvasVersions.encode(allocated)
    assert bytes == ~s({"allocated":"0.1.0","version":1})
    assert digest == Prima.JCS.hash_binary(bytes)
    assert stored_row(actor, name).digest == digest

    working =
      document(%{
        allocated: "0.1.1",
        working: "0.1.1",
        kept: "0.1.0",
        failed: %{version: "0.1.0", outcome: "died", at: "2026-10-09T12:00:00Z"}
      })

    assert {:ok, 2} = CanvasVersions.publish(actor, name, working, 1)
    assert {:ok, %{document: ^working, revision: 2}} = CanvasVersions.get(actor, name)
  end

  test "a publication over a newer revision is refused and leaves the document", %{
    actor: actor,
    name: name
  } do
    {:ok, 1} = CanvasVersions.publish(actor, name, document(%{allocated: "0.1.0"}), 0)
    {:ok, 2} = CanvasVersions.publish(actor, name, document(%{allocated: "0.1.1"}), 1)

    late = document(%{allocated: "0.1.9"})
    assert {:error, :stale} = CanvasVersions.publish(actor, name, late, 1)
    assert {:error, :stale} = CanvasVersions.publish(actor, name, late, 0)

    assert {:ok, %{revision: 2, document: %{allocated: "0.1.1"}}} =
             CanvasVersions.get(actor, name)

    # The refused attempts' staged bytes are handed to the sweep.
    refused =
      Arca.Repo.all(
        from(s in StorageStaging,
          where: s.athanor_id == ^actor.athanor_id and s.state == "reserved"
        )
      )

    now = Arca.ServerMetaStorage.now!()
    assert Enum.all?(refused, &(DateTime.compare(&1.expires_at, now) != :gt))
  end

  test "each canvas has one document, and each athanor its own", %{actor: actor, name: name} do
    {:ok, 1} = CanvasVersions.publish(actor, name, document(%{allocated: "0.1.0"}), 0)
    assert {:error, :not_found} = CanvasVersions.get(actor, "weather")

    elsewhere =
      Arca.Test.Actor.local(athanor_id: "ath_cnv_other_#{System.unique_integer([:positive])}")

    assert {:error, :not_found} = CanvasVersions.get(elsewhere, name)
    assert {:ok, 1} = CanvasVersions.publish(elsewhere, name, document(%{allocated: "2.0.0"}), 0)
    assert {:ok, %{document: %{allocated: "0.1.0"}}} = CanvasVersions.get(actor, name)
  end

  test "a member that lost its slot publishes nothing", %{actor: actor, name: name, slot: slot} do
    assert {:ok, 1} = CanvasVersions.publish(actor, name, document(%{allocated: "0.1.0"}), 0)

    {1, _} =
      Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
        set: [owner: "someone-else", generation: slot.generation + 1]
      )

    assert {:error, :not_owner} =
             CanvasVersions.publish(actor, name, document(%{allocated: "0.1.1"}), 1)

    assert {:ok, %{revision: 1, document: %{allocated: "0.1.0"}}} =
             CanvasVersions.get(actor, name)
  end

  test "stored bytes that no longer hold their digest, or that the codec did not write, read as corrupt",
       %{actor: actor, name: name} do
    {:ok, 1} = CanvasVersions.publish(actor, name, document(%{allocated: "0.1.0"}), 0)
    %{digest: digest} = stored_row(actor, name)

    {1, _} =
      Arca.Repo.update_all(row_query(actor, name),
        set: [digest: "sha256:" <> String.duplicate("0", 64)]
      )

    assert {:error, :corrupt} = CanvasVersions.get(actor, name)

    {1, _} = Arca.Repo.update_all(row_query(actor, name), set: [digest: digest])
    assert {:ok, %{revision: 1}} = CanvasVersions.get(actor, name)

    # The reference pointed, by hand, at bytes that hold the digest it
    # records but are no document this codec writes: a field it does not
    # know.
    foreign = ~s({"allocated":"0.1.0","pinned":"0.0.1","version":1})
    {:ok, staged} = Arca.Storage.stage(actor, "canvases", foreign)

    {1, _} =
      Arca.Repo.update_all(row_query(actor, name),
        set: [blob_key: "staging/" <> staged, digest: Prima.JCS.hash_binary(foreign)]
      )

    assert {:error, :corrupt} = CanvasVersions.get(actor, name)
  end

  test "the codec writes only a document, and reads only what it writes" do
    full =
      document(%{
        allocated: "1.2.3",
        working: "1.2.2",
        kept: "1.2.1",
        failed: %{version: "1.2.3", outcome: "no_tree", at: "2026-10-09T08:30:00Z"}
      })

    {:ok, bytes} = CanvasVersions.encode(full)
    assert {:ok, ^full} = CanvasVersions.decode(bytes)
    assert {:ok, ~s({"version":1})} = CanvasVersions.encode(document())
    assert CanvasVersions.outcomes() == ["no_tree", "died"]

    for bad <- [
          %{document() | version: 2},
          Map.put(document(), :pinned, nil),
          Map.delete(document(), :kept),
          document(%{allocated: "1.2"}),
          document(%{working: "01.2.3"}),
          document(%{kept: "1.2.3-beta"}),
          document(%{allocated: 7}),
          document(%{failed: %{version: "1.0.0", outcome: "tree", at: "2026-10-09T08:30:00Z"}}),
          document(%{failed: %{version: "1.0.0", outcome: "died", at: "2026-10-09T08:30:00.5Z"}}),
          document(%{failed: %{version: "1.0.0", outcome: "died", at: "2026-10-09 08:30:00"}}),
          document(%{failed: %{version: "1.0.0", outcome: "died", at: "2026-13-09T08:30:00Z"}}),
          document(%{failed: %{version: "1.0.0", outcome: "died"}}),
          "not a document"
        ] do
      assert {:error, :invalid_document} = CanvasVersions.encode(bad), inspect(bad)
    end

    # Bytes that mean a document but are not its canonical form, or that
    # carry what the codec omits, are not read as one.
    for bytes <- [
          ~s({"version": 1}),
          ~s({"version":1,"allocated":"0.1.0"}),
          ~s({"allocated":null,"version":1}),
          ~s({"version":2}),
          ~s({"failed":{"at":"2026-10-09T08:30:00Z","outcome":"died","version":"1.0.0","why":"x"},"version":1}),
          ~s([1]),
          "not json",
          7
        ] do
      assert {:error, :invalid_document} = CanvasVersions.decode(bytes), inspect(bytes)
    end
  end

  test "a name outside the component-name grammar, a term that is no document and an actor naming no athanor are refused",
       %{actor: actor} do
    for bad <- [nil, "", "Markets", "a/b", "../x", "-markets", String.duplicate("m", 65)] do
      assert {:error, :invalid_name} = CanvasVersions.get(actor, bad)
      assert {:error, :invalid_name} = CanvasVersions.publish(actor, bad, document(), 0)
    end

    assert {:error, :invalid_document} =
             CanvasVersions.publish(actor, "markets", %{version: 1}, 0)

    assert {:error, :no_athanor} =
             CanvasVersions.publish(Prima.Actor.system(), "markets", document(), 0)

    assert {:error, :no_athanor} = CanvasVersions.get(Prima.Actor.system(), "markets")
  end
end
