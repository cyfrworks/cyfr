# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.LayoutsTest do
  @moduledoc """
  The per-person layout documents: published fenced over the revision the
  writer read, read back as the document with its revision and digest,
  one per person in the actor's athanor; a publication over a newer
  revision is refused, a member that lost its slot publishes nothing,
  bytes that no longer hold their digest read as corrupt, and bytes that
  hold it but name a version this code does not read are told apart, at
  their revision, so the next publication replaces them.
  """

  # Takes a slot through `Arca.ControlPlane`, which writes the process-wide
  # standing record; each case saves and restores it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ControlPlane
  alias Arca.Layouts
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

    athanor = "ath_lay_#{System.unique_integer([:positive])}"
    {:ok, actor: Arca.Test.Actor.local(athanor_id: athanor), user: "usr_lay", slot: hold_slot!()}
  end

  defp layout(canvas \\ "tincture:local.canvas") do
    {:ok, layout} =
      Prima.Layout.validate(%{
        "version" => 3,
        "canvases" => [
          %{
            "id" => "home",
            "tincture" => canvas,
            "postures" => %{
              "hand" => %{
                "apps" => [
                  %{
                    "tincture" => "tincture:acme.uninstalled",
                    "placement" => "full",
                    "order" => 0,
                    "minimised" => false
                  }
                ]
              }
            }
          }
        ]
      })

    layout
  end

  # Bytes published as the layout's over `revision_read`, as an earlier
  # CYFR, whose documents this one does not read, published its own.
  defp publish_bytes!(actor, user, bytes, revision_read) do
    {:ok, staged} = Arca.Storage.stage(actor, "layouts", bytes)
    {:ok, slot} = ControlPlane.member_slot()

    change = %Arca.FencedPublication.Change{
      resource: {:document, actor.athanor_id, Layouts.key(user)},
      staged: staged,
      digest: Prima.Digest.sha256(bytes)
    }

    {:ok, revision} = Arca.FencedPublication.publish(change, revision_read, slot)
    revision
  end

  # A claimant runs, and this member holds its slot.
  defp hold_slot! do
    Application.put_env(:arca, :control_plane_claim_enabled, true)
    node = "node-lay-#{System.unique_integer([:positive])}"
    {:ok, slot} = ControlPlane.take(node, node <> "#boot_a", 60_000)
    slot
  end

  test "a layout never published is not found", %{actor: actor, user: user} do
    assert {:error, :not_found} = Layouts.get(actor, user)
  end

  test "a publication reads back as the document, its revision and its digest", %{
    actor: actor,
    user: user
  } do
    layout = layout()
    assert {:ok, 1} = Layouts.publish(actor, user, layout, 0)

    assert {:ok, %{document: ^layout, revision: 1, digest: digest}} = Layouts.get(actor, user)
    assert digest == Prima.Layout.digest(layout)

    # A tincture nobody installed is kept as it was written.
    assert "tincture:acme.uninstalled" in Prima.Layout.tinctures(layout)

    moved = layout("tincture:local.other")
    assert {:ok, 2} = Layouts.publish(actor, user, moved, 1)
    assert {:ok, %{document: ^moved, revision: 2}} = Layouts.get(actor, user)
  end

  test "a publication over a newer revision is refused and leaves the document", %{
    actor: actor,
    user: user
  } do
    first = layout()
    {:ok, 1} = Layouts.publish(actor, user, first, 0)
    {:ok, 2} = Layouts.publish(actor, user, layout("tincture:local.second"), 1)

    assert {:error, :stale} = Layouts.publish(actor, user, layout("tincture:local.late"), 1)
    assert {:error, :stale} = Layouts.publish(actor, user, layout("tincture:local.late"), 0)
    assert {:ok, %{revision: 2, document: document}} = Layouts.get(actor, user)
    assert [%{tincture: "tincture:local.second"}] = document.canvases

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

  test "each person has one layout, and each athanor its own", %{actor: actor, user: user} do
    {:ok, 1} = Layouts.publish(actor, user, layout(), 0)
    assert {:error, :not_found} = Layouts.get(actor, "usr_someone_else")

    elsewhere =
      Arca.Test.Actor.local(athanor_id: "ath_lay_other_#{System.unique_integer([:positive])}")

    assert {:error, :not_found} = Layouts.get(elsewhere, user)
    assert {:ok, 1} = Layouts.publish(elsewhere, user, layout(), 0)
  end

  test "a member that lost its slot publishes nothing", %{actor: actor, user: user, slot: slot} do
    assert {:ok, 1} = Layouts.publish(actor, user, layout(), 0)

    {1, _} =
      Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
        set: [owner: "someone-else", generation: slot.generation + 1]
      )

    assert {:error, :not_owner} =
             Layouts.publish(actor, user, layout("tincture:local.late"), 1)

    assert {:ok, %{revision: 1}} = Layouts.get(actor, user)
  end

  test "bytes that no longer hold the digest their reference records read as corrupt", %{
    actor: actor,
    user: user
  } do
    {:ok, 1} = Layouts.publish(actor, user, layout(), 0)
    key = Layouts.key(user)

    {1, _} =
      Arca.Repo.update_all(
        from(d in FencedDocument, where: d.athanor_id == ^actor.athanor_id and d.key == ^key),
        set: [digest: "sha256:" <> String.duplicate("0", 64)]
      )

    assert {:error, :corrupt} = Layouts.get(actor, user)
  end

  test "a document of a version this code does not read is told apart at its revision, and the next publication replaces it",
       %{actor: actor, user: user} do
    for revision <- 0..5, do: {:ok, _} = Layouts.publish(actor, user, layout(), revision)

    version_2 =
      ~s({"canvases":[{"id":"home","postures":{"desk":{"apps":[{"mode":"column","order":0,) <>
        ~s("tincture":"tincture:local.vault"}],"floating":[]}},"tincture":"tincture:local.canvas"}],) <>
        ~s("version":2})

    assert publish_bytes!(actor, user, version_2, 6) == 7
    assert {:error, {:unsupported_version, 7}} = Layouts.get(actor, user)

    assert {:error, :stale} = Layouts.publish(actor, user, layout(), 6)
    assert {:ok, 8} = Layouts.publish(actor, user, layout(), 7)

    expected = layout()
    digest = Prima.Layout.digest(expected)
    assert {:ok, %{document: ^expected, revision: 8, digest: ^digest}} = Layouts.get(actor, user)
  end

  test "bytes that hold their digest but are not a layout of this version read as corrupt", %{
    actor: actor,
    user: user
  } do
    assert publish_bytes!(actor, user, ~s({"canvases":[],"version":3,"desks":[]}), 0) == 1
    assert {:error, :corrupt} = Layouts.get(actor, user)

    assert publish_bytes!(actor, user, ~s({"canvases":[]}), 1) == 2
    assert {:error, :corrupt} = Layouts.get(actor, user)

    assert publish_bytes!(actor, user, "not json", 2) == 3
    assert {:error, :corrupt} = Layouts.get(actor, user)
  end

  test "an id naming nobody and an actor naming no athanor are refused", %{actor: actor} do
    for bad <- [nil, "", "usr/../x", String.duplicate("u", 200)] do
      assert {:error, :no_person} = Layouts.get(actor, bad)
      assert {:error, :no_person} = Layouts.publish(actor, bad, layout(), 0)
    end

    assert {:error, :no_athanor} = Layouts.publish(Prima.Actor.system(), "usr_lay", layout(), 0)
    assert {:error, :no_athanor} = Layouts.get(Prima.Actor.system(), "usr_lay")
  end
end
