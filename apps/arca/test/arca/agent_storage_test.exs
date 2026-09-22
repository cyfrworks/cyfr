# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AgentStorageTest do
  @moduledoc """
  The `agents` rows, and the claim a provisioning attempt publishes them
  under.

  The index speaks for the estate, so an attempt whose claim a successor
  took must not publish one. The guard and the rewrite are one
  transaction, which is what makes the answer a decision and not a
  guess: a takeover racing it either lands first and the rewrite writes
  nothing, or waits behind the commit.

  Every case works in an athanor of its own, so what it counts is its own.
  """

  # A claim and a whole index rewrite are two write transactions on one
  # SQLite write lock, long enough that a neighbouring async case is told
  # the database is busy — so this one runs alone, as the claims suite
  # does for the same reason.
  use ExUnit.Case, async: false

  alias Arca.AgentStorage
  alias Arca.ProvisioningClaims, as: Claims

  @lease_ms 60_000

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

  test "a rewrite with no claim stands on its own", %{actor: actor, athanor_id: athanor_id} do
    assert {:ok, _} = AgentStorage.replace_all(actor, [row(athanor_id, "alpha")])
    assert names(actor) == ["alpha"]

    # A whole rewrite, never a merge.
    assert {:ok, _} = AgentStorage.replace_all(actor, [row(athanor_id, "beta")])
    assert names(actor) == ["beta"]

    assert {:ok, _} = AgentStorage.replace_all(actor, [])
    assert names(actor) == []
  end

  test "an attempt holding its claim publishes the index", %{
    actor: actor,
    athanor_id: athanor_id
  } do
    assert {:ok, claim} = Claims.claim(actor, "boot_a", "first_need", @lease_ms)

    assert {:ok, _} =
             AgentStorage.replace_all(actor, [row(athanor_id, "alpha")],
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
             AgentStorage.replace_all(actor, [row(athanor_id, "alpha")],
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
             AgentStorage.replace_all(actor, [row(athanor_id, "beta")],
               claim: %{owner: first.owner, fence: first.fence}
             )

    assert names(actor) == ["alpha"]

    # And the successor publishes under its own claim.
    assert {:ok, _} =
             AgentStorage.replace_all(actor, [row(athanor_id, "beta")],
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
             AgentStorage.replace_all(actor, [row(athanor_id, "alpha")],
               claim: %{owner: claim.owner, fence: claim.fence}
             )

    assert names(actor) == []
  end

  test "an actor without an athanor is refused before any query" do
    nobody = %Cyfr.Actor{athanor_id: nil, user_id: "someone"}

    assert AgentStorage.replace_all(nobody, []) == {:error, :no_athanor}
    assert AgentStorage.list(nobody) == {:error, :no_athanor}
  end
end
