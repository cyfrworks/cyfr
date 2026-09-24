# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AgentStorageTest do
  @moduledoc """
  The `agents` rows, the `aqua` root's projection, and the claim a
  provisioning attempt publishes them under.

  The index speaks for the estate, so an attempt whose claim a successor
  took must not publish one. The guard, the rewrite and its
  acknowledgment are one transaction, which is what makes the answer a
  decision and not a guess: a takeover racing it either lands first and
  the rewrite writes nothing, or waits behind the commit — and a rewrite
  that writes nothing acknowledges nothing.

  Every case works in an athanor of its own, so what it counts is its own.
  """

  # A claim and a whole index rewrite are two write transactions on one
  # SQLite write lock, long enough that a neighbouring async case is told
  # the database is busy — so this one runs alone, as the claims suite
  # does for the same reason.
  use ExUnit.Case, async: false

  alias Arca.AgentStorage
  alias Arca.ProvisioningClaims, as: Claims
  alias Arca.{StorageProjectionChanges, StorageProjectionRoots}

  @lease_ms 60_000
  @root "aqua"

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    athanor_id = "ath_agents_#{System.unique_integer([:positive])}"
    {:ok, actor: %Cyfr.Actor{athanor_id: athanor_id}, athanor_id: athanor_id}
  end

  defp row(athanor_id, name) do
    %{
      id: Cyfr.UUID7.generate_id("agt"),
      athanor_id: athanor_id,
      name: name,
      kind: "role",
      revision_digest: "sha256:#{name}",
      capability_digest: "sha256:cap-#{name}",
      disabled: false,
      synced_at: DateTime.utc_now()
    }
  end

  defp names(actor) do
    {:ok, rows} = AgentStorage.list(actor)
    Enum.map(rows, & &1.name)
  end

  defp token(actor) do
    {:ok, token} = StorageProjectionChanges.snapshot(actor, @root)
    token
  end

  defp standing(actor) do
    {:ok, standing} = StorageProjectionRoots.epoch(actor, @root)
    standing
  end

  # A role edited in the tree: its pending generation, then a ready one.
  defp edited!(actor, name) do
    {:ok, pending} = StorageProjectionChanges.begin_edit(actor, @root, "roles/#{name}.md")
    {:ok, ready} = StorageProjectionChanges.finish_edit(actor, @root, "roles/#{name}.md", pending)
    ready
  end

  test "a rewrite with no claim stands on its own", %{actor: actor, athanor_id: athanor_id} do
    assert {:ok, _} = AgentStorage.replace_projection(actor, token(actor), [row(athanor_id, "alpha")])
    assert names(actor) == ["alpha"]

    # A whole rewrite, never a merge.
    assert {:ok, _} = AgentStorage.replace_projection(actor, token(actor), [row(athanor_id, "beta")])
    assert names(actor) == ["beta"]

    assert {:ok, _} = AgentStorage.replace_projection(actor, token(actor), [])
    assert names(actor) == []
  end

  test "a rewrite acknowledges the root it was made against", %{
    actor: actor,
    athanor_id: athanor_id
  } do
    generation = edited!(actor, "alpha")
    assert %{epoch: ^generation, acknowledged_epoch: 0} = standing(actor)

    assert {:ok, _} = AgentStorage.replace_projection(actor, token(actor), [row(athanor_id, "alpha")])
    assert %{epoch: ^generation, acknowledged_epoch: ^generation} = standing(actor)
    assert {:ok, %{units: []}} = StorageProjectionChanges.snapshot(actor, @root)
  end

  test "an attempt holding its claim publishes the index", %{
    actor: actor,
    athanor_id: athanor_id
  } do
    assert {:ok, claim} = Claims.claim(actor, "boot_a", "first_need", @lease_ms)

    assert {:ok, _} =
             AgentStorage.replace_projection(actor, token(actor), [row(athanor_id, "alpha")],
               claim: %{owner: claim.owner, fence: claim.fence}
             )

    assert names(actor) == ["alpha"]
  end

  test "an attempt whose claim a successor took publishes nothing", %{
    actor: actor,
    athanor_id: athanor_id
  } do
    assert {:ok, first} = Claims.claim(actor, "boot_a", "first_need", @lease_ms)

    assert {:ok, _} =
             AgentStorage.replace_projection(actor, token(actor), [row(athanor_id, "alpha")],
               claim: %{owner: first.owner, fence: first.fence}
             )

    # The successor takes the claim — settling the predecessor's is what
    # makes the row takeable, and the take raises the fence.
    assert :ok = Claims.settle(actor, first.owner, first.fence, "failed", nil)
    assert {:ok, second} = Claims.claim(actor, "boot_b", "seed_sync", @lease_ms)
    assert second.fence > first.fence

    # The predecessor's rewrite writes nothing at all: the rows it would
    # have deleted are still there, so a lost claim cannot even empty the
    # index on its way out.
    assert {:error, :claim_lost} =
             AgentStorage.replace_projection(actor, token(actor), [row(athanor_id, "beta")],
               claim: %{owner: first.owner, fence: first.fence}
             )

    assert names(actor) == ["alpha"]

    # And the successor publishes under its own claim.
    assert {:ok, _} =
             AgentStorage.replace_projection(actor, token(actor), [row(athanor_id, "beta")],
               claim: %{owner: second.owner, fence: second.fence}
             )

    assert names(actor) == ["beta"]
  end

  test "a settled claim publishes nothing, lease or no lease", %{
    actor: actor,
    athanor_id: athanor_id
  } do
    assert {:ok, claim} = Claims.claim(actor, "boot_a", "first_need", @lease_ms)
    assert :ok = Claims.settle(actor, claim.owner, claim.fence, "ready", nil)

    assert {:error, :claim_lost} =
             AgentStorage.replace_projection(actor, token(actor), [row(athanor_id, "alpha")],
               claim: %{owner: claim.owner, fence: claim.fence}
             )

    assert names(actor) == []
  end

  describe "the rows and their acknowledgment" do
    test "roll back together when the claim is lost", %{actor: actor, athanor_id: athanor_id} do
      assert {:ok, claim} = Claims.claim(actor, "boot_a", "first_need", @lease_ms)
      assert :ok = Claims.settle(actor, claim.owner, claim.fence, "failed", nil)
      generation = edited!(actor, "alpha")

      assert {:error, :claim_lost} =
               AgentStorage.replace_projection(actor, token(actor), [row(athanor_id, "alpha")],
                 claim: %{owner: claim.owner, fence: claim.fence}
               )

      assert names(actor) == []
      assert %{epoch: ^generation, acknowledged_epoch: 0} = standing(actor)
      assert {:ok, %{units: [%{acknowledged_generation: 0}]}} = StorageProjectionChanges.snapshot(actor, @root)
    end

    @tag :capture_log
    test "roll back together when a row cannot be written", %{
      actor: actor,
      athanor_id: athanor_id
    } do
      assert {:ok, _} = AgentStorage.replace_projection(actor, token(actor), [row(athanor_id, "alpha")])
      generation = edited!(actor, "beta")

      # `kind` is NOT NULL: the insert fails after the delete, inside the
      # transaction that would have acknowledged the edit.
      broken = %{row(athanor_id, "beta") | kind: nil}

      assert {:error, :database_error} =
               AgentStorage.replace_projection(actor, token(actor), [row(athanor_id, "alpha"), broken])

      assert names(actor) == ["alpha"]
      assert %{epoch: ^generation, acknowledged_epoch: previous} = standing(actor)
      assert previous < generation
    end

    test "a change the snapshot did not see refuses the whole rewrite", %{
      actor: actor,
      athanor_id: athanor_id
    } do
      stale = token(actor)
      _created_since = edited!(actor, "gamma")

      assert {:error, :generation_conflict} =
               AgentStorage.replace_projection(actor, stale, [row(athanor_id, "alpha")])

      assert names(actor) == []
    end
  end

  test "an actor without an athanor, and another athanor's token, are refused before any write",
       %{actor: actor, athanor_id: athanor_id} do
    nobody = %Cyfr.Actor{athanor_id: nil, user_id: "someone"}
    assert AgentStorage.replace_projection(nobody, token(actor), []) == {:error, :no_athanor}
    assert AgentStorage.replace_projection(%{nobody | athanor_id: ""}, token(actor), []) ==
             {:error, :no_athanor}

    assert AgentStorage.list(nobody) == {:error, :no_athanor}

    other = %Cyfr.Actor{athanor_id: "#{athanor_id}_other"}
    assert {:ok, _} = AgentStorage.replace_projection(actor, token(actor), [row(athanor_id, "alpha")])

    assert {:error, :cross_tenant} =
             AgentStorage.replace_projection(other, token(actor), [row(other.athanor_id, "x")])

    assert names(other) == []
    assert names(actor) == ["alpha"]
  end
end
