# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.FrameCredentialsTest do
  @moduledoc """
  The per-open frame credential rows: minted active, only with a frame id
  and a deadline, once per frame id in an athanor, and only by a member
  that owns its slot; suspended, resumed (under ownership, before the
  deadline) and revoked, with `revoked` terminal; read and written only in
  the actor's own athanor; revoked by source and by person, across
  athanors only for the platform's own actor; and swept by retention only
  once revoked and aged.
  """

  # Takes a slot through `Arca.ControlPlane`, which writes the process-wide
  # standing record; each case saves and restores it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ControlPlane
  alias Arca.FrameCredentials
  alias Arca.Schemas.{CellLease, FrameCredential}

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

    # A claimant runs, and this member holds its slot.
    Application.put_env(:arca, :control_plane_claim_enabled, true)
    node = "node-frc-#{System.unique_integer([:positive])}"
    {:ok, slot} = ControlPlane.take(node, node <> "#boot_a", 60_000)

    athanor = "ath_frc_#{System.unique_integer([:positive])}"
    {:ok, actor: Prima.Actor.in_athanor(athanor), slot: slot}
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        user_id: "usr_frc",
        publisher: "acme",
        name: "dash",
        version: "1.0.0",
        version_digest: "sha256:" <> String.duplicate("a", 64),
        grant_revision: 3,
        frame_id: "frm_#{System.unique_integer([:positive])}",
        source_kind: "session",
        source_id: "c2Vzc2lvbi1oYXNo",
        deadline: DateTime.add(DateTime.utc_now(), 600, :second)
      },
      overrides
    )
  end

  defp mint!(actor, overrides \\ %{}) do
    {:ok, row} = FrameCredentials.mint(actor, attrs(overrides))
    row
  end

  describe "mint/2" do
    test "records an active row in the actor's athanor, as a plain map", %{actor: actor} do
      assert {:ok, row} = FrameCredentials.mint(actor, attrs())
      refute is_struct(row)
      assert "frc_" <> _ = row.id
      assert row.state == "active"
      assert row.athanor_id == actor.athanor_id
      assert {row.publisher, row.name, row.version} == {"acme", "dash", "1.0.0"}
      assert FrameCredentials.get(actor, row.id) == {:ok, row}
    end

    test "a frame credential without a frame id or without a deadline is refused", %{actor: actor} do
      assert {:error, {:invalid, %{frame_id: _}}} =
               FrameCredentials.mint(actor, Map.delete(attrs(), :frame_id))

      assert {:error, {:invalid, %{deadline: _}}} =
               FrameCredentials.mint(actor, Map.delete(attrs(), :deadline))

      assert {:error, {:invalid, %{deadline: _}}} =
               FrameCredentials.mint(actor, attrs(%{deadline: nil}))

      assert {:error, {:invalid, %{source_kind: _}}} =
               FrameCredentials.mint(actor, attrs(%{source_kind: "cookie"}))

      assert {:error, {:invalid, %{grant_revision: _}}} =
               FrameCredentials.mint(actor, attrs(%{grant_revision: -1}))

      assert {:error, {:invalid, %{version: _}}} =
               FrameCredentials.mint(actor, Map.delete(attrs(), :version))

      assert Arca.Repo.aggregate(FrameCredential, :count) == 0
    end

    test "one frame id per athanor", %{actor: actor} do
      row = mint!(actor)
      assert {:error, :conflict} = FrameCredentials.mint(actor, attrs(%{frame_id: row.frame_id}))

      other = Prima.Actor.in_athanor("ath_frc_other_#{System.unique_integer([:positive])}")
      assert {:ok, _} = FrameCredentials.mint(other, attrs(%{frame_id: row.frame_id}))
    end

    test "a stale owner mints nothing", %{actor: actor, slot: slot} do
      {1, _} =
        Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
          set: [owner: "someone-else", generation: slot.generation + 1]
        )

      assert {:error, :not_owner} = FrameCredentials.mint(actor, attrs())
      assert Arca.Repo.aggregate(FrameCredential, :count) == 0
    end

    test "an actor that names no athanor is refused" do
      assert {:error, :no_athanor} = FrameCredentials.mint(Prima.Actor.system(), attrs())
    end
  end

  describe "the state machine" do
    test "suspend, resume and revoke; revoked is terminal", %{actor: actor} do
      row = mint!(actor)

      assert {:ok, %{state: "suspended"}} = FrameCredentials.suspend(actor, row.id)
      assert {:ok, %{state: "suspended"}} = FrameCredentials.suspend(actor, row.id)
      assert {:ok, %{state: "active"}} = FrameCredentials.resume(actor, row.id)
      assert {:ok, %{state: "active"}} = FrameCredentials.resume(actor, row.id)
      assert {:ok, %{state: "revoked"} = revoked} = FrameCredentials.revoke(actor, row.id)
      assert {:ok, ^revoked} = FrameCredentials.revoke(actor, row.id)

      assert {:error, :revoked} = FrameCredentials.suspend(actor, row.id)
      assert {:error, :revoked} = FrameCredentials.resume(actor, row.id)
    end

    test "a resume past the deadline, or by a stale owner, re-opens nothing", %{
      actor: actor,
      slot: slot
    } do
      past = mint!(actor, %{deadline: DateTime.add(DateTime.utc_now(), -1, :second)})
      {:ok, _} = FrameCredentials.suspend(actor, past.id)
      assert {:error, :expired} = FrameCredentials.resume(actor, past.id)
      assert {:ok, %{state: "suspended"}} = FrameCredentials.get(actor, past.id)

      row = mint!(actor)
      {:ok, _} = FrameCredentials.suspend(actor, row.id)

      {1, _} =
        Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
          set: [owner: "someone-else", generation: slot.generation + 1]
        )

      assert {:error, :not_owner} = FrameCredentials.resume(actor, row.id)
      # A member that lost its slot may still close what it opened.
      assert {:ok, %{state: "revoked"}} = FrameCredentials.revoke(actor, row.id)
    end

    test "another athanor's row is not found", %{actor: actor} do
      row = mint!(actor)
      other = Prima.Actor.in_athanor("ath_frc_other")

      for verb <- [:get, :suspend, :resume, :revoke] do
        assert {:error, :not_found} = apply(FrameCredentials, verb, [other, row.id])
      end

      assert {:ok, %{state: "active"}} = FrameCredentials.get(actor, row.id)
      assert {:error, :no_athanor} = FrameCredentials.get(Prima.Actor.system(), row.id)
    end
  end

  describe "revocation by source and by person" do
    test "revokes every unrevoked row of the source, in the actor's athanor", %{actor: actor} do
      a = mint!(actor)
      b = mint!(actor)
      {:ok, _} = FrameCredentials.suspend(actor, b.id)
      other_source = mint!(actor, %{source_kind: "api_key", source_id: "key_1"})

      assert {:ok, ids} = FrameCredentials.revoke_for_source(actor, {:session, a.source_id})
      assert ids == Enum.sort([a.id, b.id])
      assert {:ok, %{state: "active"}} = FrameCredentials.get(actor, other_source.id)
      assert {:ok, []} = FrameCredentials.revoke_for_source(actor, {:session, a.source_id})
    end

    test "a person's rows go in every athanor only for the platform's own actor", %{actor: actor} do
      elsewhere =
        Prima.Actor.in_athanor("ath_frc_elsewhere_#{System.unique_integer([:positive])}")

      here = mint!(actor)
      there = mint!(elsewhere)
      theirs = mint!(actor, %{user_id: "usr_other"})

      assert {:ok, [here_id]} = FrameCredentials.revoke_for_user(actor, "usr_frc")
      assert here_id == here.id
      assert {:ok, %{state: "active"}} = FrameCredentials.get(elsewhere, there.id)

      assert {:ok, [there_id]} = FrameCredentials.revoke_for_user(Prima.Actor.system(), "usr_frc")
      assert there_id == there.id
      assert {:ok, %{state: "active"}} = FrameCredentials.get(actor, theirs.id)

      assert {:error, :no_athanor} =
               FrameCredentials.revoke_for_user(
                 %{Prima.Actor.system() | system: false},
                 "usr_frc"
               )
    end
  end

  describe "retention" do
    test "sweeps revoked rows past the athanor's days, and never a standing one", %{actor: actor} do
      assert Arca.Retention.FrameCredentials in Arca.Retention.kinds()
      assert Arca.Retention.FrameCredentials.key() == "frame_credential_days"
      assert Arca.Retention.FrameCredentials.unit() == :days

      old = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)
      aged = mint!(actor)
      {:ok, _} = FrameCredentials.revoke(actor, aged.id)
      fresh = mint!(actor)
      {:ok, _} = FrameCredentials.revoke(actor, fresh.id)
      standing = mint!(actor)
      suspended = mint!(actor)
      {:ok, _} = FrameCredentials.suspend(actor, suspended.id)

      ids = [aged.id, standing.id, suspended.id]

      {3, _} =
        Arca.Repo.update_all(from(f in FrameCredential, where: f.id in ^ids),
          set: [updated_at: old]
        )

      assert {:ok, 1} = Arca.Retention.FrameCredentials.prune(actor, 7, true)
      assert {:ok, 1} = Arca.Retention.FrameCredentials.prune(actor, 7, false)
      assert {:error, :not_found} = FrameCredentials.get(actor, aged.id)

      for row <- [fresh, standing, suspended],
          do: assert({:ok, _} = FrameCredentials.get(actor, row.id))

      assert {:error, :no_athanor} =
               Arca.Retention.FrameCredentials.prune(Prima.Actor.system(), 7, true)
    end
  end
end
