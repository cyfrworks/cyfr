# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.FrameCredentialsTest do
  @moduledoc """
  The per-open frame credential rows: minted active, `live` unless minted
  for validation, only with a frame id and a deadline, once per frame id
  in an athanor, and only by a member that owns its slot; suspended,
  resumed (under ownership, with the new deadline, a suspended row
  whatever its old one) and revoked, with `revoked` terminal; an active
  row renewed (under ownership, before its deadline) with only its
  deadline moved; a validation row never suspended, resumed or renewed;
  a validation row consumed once, by its own person, before its deadline,
  for its own digest and under ownership, and nothing else consumed;
  read and written only in the actor's own athanor, and read by frame id
  only as its own person's; revoked by source and
  by person, across athanors only for the platform's own actor; and swept
  by retention only once revoked and aged.
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

  @digest "sha256:" <> String.duplicate("a", 64)

  # The actor of the person the rows are minted for.
  defp person(actor, user_id \\ "usr_frc"), do: %{actor | user_id: user_id}

  defp in_s(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp take_over!(slot) do
    {1, _} =
      Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
        set: [owner: "someone-else", generation: slot.generation + 1]
      )

    :ok
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

    test "a row is live unless minted for validation, and no other purpose is minted", %{
      actor: actor
    } do
      assert FrameCredential.purposes() == ~w(live validation)
      assert %{purpose: "live"} = mint!(actor)
      assert %{purpose: "validation"} = validation = mint!(actor, %{purpose: "validation"})
      assert {:ok, %{purpose: "validation"}} = FrameCredentials.get(actor, validation.id)

      for purpose <- ["trial", "Validation", nil, :validation] do
        assert {:error, {:invalid, %{purpose: _}}} =
                 FrameCredentials.mint(actor, attrs(%{purpose: purpose}))
      end

      assert Arca.Repo.aggregate(FrameCredential, :count) == 2
    end
  end

  describe "the state machine" do
    test "suspend, resume and revoke; revoked is terminal", %{actor: actor} do
      row = mint!(actor)

      later = in_s(1_200)

      assert {:ok, %{state: "suspended"}} = FrameCredentials.suspend(actor, row.id)
      assert {:ok, %{state: "suspended"}} = FrameCredentials.suspend(actor, row.id)

      assert {:ok, %{state: "active", deadline: ^later}} =
               FrameCredentials.resume(actor, row.id, later)

      # An active row before its deadline answers as it is.
      assert {:ok, %{state: "active", deadline: ^later}} =
               FrameCredentials.resume(actor, row.id, in_s(1_800))

      assert {:ok, %{state: "revoked"} = revoked} = FrameCredentials.revoke(actor, row.id)
      assert {:ok, ^revoked} = FrameCredentials.revoke(actor, row.id)

      assert {:error, :revoked} = FrameCredentials.suspend(actor, row.id)
      assert {:error, :revoked} = FrameCredentials.resume(actor, row.id, in_s(600))
      assert {:ok, ^revoked} = FrameCredentials.get(actor, row.id)
    end

    test "a suspended row past its deadline is resumed with the new one; an active one is not",
         %{actor: actor} do
      past = mint!(actor, %{deadline: in_s(-1)})
      {:ok, _} = FrameCredentials.suspend(actor, past.id)
      fresh = in_s(600)

      assert {:ok, %{state: "active", deadline: ^fresh} = resumed} =
               FrameCredentials.resume(actor, past.id, fresh)

      assert {:ok, ^resumed} = FrameCredentials.get(actor, past.id)

      ran_out = mint!(actor, %{deadline: in_s(-1)})
      assert {:error, :expired} = FrameCredentials.resume(actor, ran_out.id, in_s(600))
      assert {:ok, ^ran_out} = FrameCredentials.get(actor, ran_out.id)

      # A deadline already past is no deadline to resume under.
      suspended = mint!(actor)
      {:ok, held} = FrameCredentials.suspend(actor, suspended.id)
      assert {:error, :expired} = FrameCredentials.resume(actor, suspended.id, in_s(-1))
      assert {:ok, ^held} = FrameCredentials.get(actor, suspended.id)
    end

    test "a resume that keeps the deadline re-opens a row only before it", %{actor: actor} do
      row = mint!(actor)
      {:ok, _} = FrameCredentials.suspend(actor, row.id)
      deadline = row.deadline

      assert {:ok, %{state: "active", deadline: ^deadline}} =
               FrameCredentials.resume(actor, row.id, :keep)

      past = mint!(actor, %{deadline: in_s(-1)})
      {:ok, suspended} = FrameCredentials.suspend(actor, past.id)
      assert {:error, :expired} = FrameCredentials.resume(actor, past.id, :keep)
      assert {:ok, ^suspended} = FrameCredentials.get(actor, past.id)
    end

    test "a resume by a stale owner re-opens nothing", %{actor: actor, slot: slot} do
      row = mint!(actor)
      {:ok, suspended} = FrameCredentials.suspend(actor, row.id)
      take_over!(slot)

      assert {:error, :not_owner} = FrameCredentials.resume(actor, row.id, in_s(600))
      assert {:ok, ^suspended} = FrameCredentials.get(actor, row.id)
      # A member that lost its slot may still close what it opened.
      assert {:ok, %{state: "revoked"}} = FrameCredentials.revoke(actor, row.id)
    end

    test "another athanor's row is not found", %{actor: actor} do
      row = mint!(actor)
      other = Prima.Actor.in_athanor("ath_frc_other")

      for verb <- [:get, :suspend, :revoke] do
        assert {:error, :not_found} = apply(FrameCredentials, verb, [other, row.id])
      end

      for verb <- [:resume, :renew] do
        assert {:error, :not_found} = apply(FrameCredentials, verb, [other, row.id, in_s(600)])
      end

      assert {:ok, %{state: "active"}} = FrameCredentials.get(actor, row.id)
      assert {:error, :no_athanor} = FrameCredentials.get(Prima.Actor.system(), row.id)
    end

    test "a validation row is neither suspended nor resumed, and is revoked as any row is", %{
      actor: actor
    } do
      row = mint!(actor, %{purpose: "validation"})

      assert {:error, :validation} = FrameCredentials.suspend(actor, row.id)
      assert {:error, :validation} = FrameCredentials.resume(actor, row.id, in_s(600))
      assert {:error, :validation} = FrameCredentials.renew(actor, row.id, in_s(600))
      assert FrameCredentials.get(actor, row.id) == {:ok, row}

      assert {:ok, %{state: "revoked", purpose: "validation"} = revoked} =
               FrameCredentials.revoke(actor, row.id)

      assert {:ok, ^revoked} = FrameCredentials.revoke(actor, row.id)
      assert {:error, :validation} = FrameCredentials.suspend(actor, row.id)
      assert {:error, :validation} = FrameCredentials.resume(actor, row.id, in_s(600))
      assert FrameCredentials.get(actor, row.id) == {:ok, revoked}
    end
  end

  describe "renew/3" do
    test "moves an active row's deadline, and nothing else about it", %{actor: actor} do
      row = mint!(actor)
      later = in_s(1_200)

      assert {:ok, renewed} = FrameCredentials.renew(actor, row.id, later)
      assert renewed.deadline == later
      assert DateTime.compare(renewed.deadline, row.deadline) == :gt

      assert Map.drop(renewed, [:deadline, :updated_at]) ==
               Map.drop(row, [:deadline, :updated_at])

      assert {:ok, ^renewed} = FrameCredentials.get(actor, row.id)
    end

    test "a suspended, a revoked, an expired or a validation row is not renewed", %{actor: actor} do
      suspended = mint!(actor)
      {:ok, suspended} = FrameCredentials.suspend(actor, suspended.id)
      revoked = mint!(actor)
      {:ok, revoked} = FrameCredentials.revoke(actor, revoked.id)
      expired = mint!(actor, %{deadline: in_s(-1)})
      validation = mint!(actor, %{purpose: "validation"})
      active = mint!(actor)

      assert {:error, :suspended} = FrameCredentials.renew(actor, suspended.id, in_s(600))
      assert {:error, :revoked} = FrameCredentials.renew(actor, revoked.id, in_s(600))
      assert {:error, :expired} = FrameCredentials.renew(actor, expired.id, in_s(600))
      assert {:error, :validation} = FrameCredentials.renew(actor, validation.id, in_s(600))
      assert {:error, :expired} = FrameCredentials.renew(actor, active.id, in_s(-1))

      for row <- [suspended, revoked, expired, validation, active] do
        assert {:ok, ^row} = FrameCredentials.get(actor, row.id)
      end
    end

    test "a stale owner renews nothing, refused inside the transaction", %{
      actor: actor,
      slot: slot
    } do
      row = mint!(actor)
      # The member still believes it holds its slot: only the lease row,
      # read inside the renew's transaction, says it does not.
      take_over!(slot)
      assert Arca.ControlPlane.held?()

      assert {:error, :not_owner} = FrameCredentials.renew(actor, row.id, in_s(1_200))
      assert {:ok, ^row} = FrameCredentials.get(actor, row.id)
    end

    test "an actor that names no athanor is refused" do
      assert {:error, :no_athanor} =
               FrameCredentials.renew(Prima.Actor.system(), "frc_x", in_s(60))

      assert {:error, :no_athanor} =
               FrameCredentials.resume(Prima.Actor.system(), "frc_x", in_s(60))
    end
  end

  describe "get_by_frame_id/2" do
    test "reads the person's row by its frame id, whatever its state or purpose", %{
      actor: actor
    } do
      live = mint!(actor)
      validation = mint!(actor, %{purpose: "validation"})

      assert FrameCredentials.get_by_frame_id(person(actor), live.frame_id) == {:ok, live}

      assert FrameCredentials.get_by_frame_id(person(actor), validation.frame_id) ==
               {:ok, validation}

      {:ok, suspended} = FrameCredentials.suspend(actor, live.id)
      assert FrameCredentials.get_by_frame_id(person(actor), live.frame_id) == {:ok, suspended}

      {:ok, revoked} = FrameCredentials.revoke(actor, live.id)
      assert FrameCredentials.get_by_frame_id(person(actor), live.frame_id) == {:ok, revoked}
    end

    test "another person's frame and another athanor's are not found", %{actor: actor} do
      row = mint!(actor)
      elsewhere = Prima.Actor.in_athanor("ath_frc_other_#{System.unique_integer([:positive])}")

      # Another person of the same athanor, the same person in another
      # athanor, and an actor that names no person.
      for stranger <- [person(actor, "usr_other"), person(elsewhere), actor] do
        assert {:error, :not_found} = FrameCredentials.get_by_frame_id(stranger, row.frame_id)
      end

      # The same frame id minted in another athanor for the same person
      # reads as that athanor's row alone.
      {:ok, theirs} = FrameCredentials.mint(elsewhere, attrs(%{frame_id: row.frame_id}))
      assert FrameCredentials.get_by_frame_id(person(actor), row.frame_id) == {:ok, row}
      assert FrameCredentials.get_by_frame_id(person(elsewhere), row.frame_id) == {:ok, theirs}

      assert {:error, :not_found} = FrameCredentials.get_by_frame_id(person(actor), "frm_absent")

      assert {:error, :no_athanor} =
               FrameCredentials.get_by_frame_id(Prima.Actor.system(), row.frame_id)
    end
  end

  describe "consume/3" do
    test "spends a validation row once, by its frame id", %{actor: actor} do
      row = mint!(actor, %{purpose: "validation"})

      assert {:ok, %{id: id, state: "revoked", purpose: "validation"} = spent} =
               FrameCredentials.consume(person(actor), row.frame_id, @digest)

      assert id == row.id
      assert DateTime.compare(spent.updated_at, row.updated_at) != :lt
      assert FrameCredentials.get(actor, row.id) == {:ok, spent}

      assert {:error, :not_live} = FrameCredentials.consume(person(actor), row.frame_id, @digest)
      assert FrameCredentials.get(actor, row.id) == {:ok, spent}
    end

    test "a live row is not consumable", %{actor: actor} do
      row = mint!(actor)

      assert {:error, :not_live} = FrameCredentials.consume(person(actor), row.frame_id, @digest)
      assert FrameCredentials.get(actor, row.id) == {:ok, row}
    end

    test "an expired row is not consumable", %{actor: actor} do
      row =
        mint!(actor, %{
          purpose: "validation",
          deadline: DateTime.add(DateTime.utc_now(), -1, :second)
        })

      assert {:error, :not_live} = FrameCredentials.consume(person(actor), row.frame_id, @digest)
      assert FrameCredentials.get(actor, row.id) == {:ok, row}
    end

    test "another person's row, another athanor's, or one revoked is not consumable", %{
      actor: actor
    } do
      row = mint!(actor, %{purpose: "validation"})
      elsewhere = Prima.Actor.in_athanor("ath_frc_other_#{System.unique_integer([:positive])}")

      for stranger <- [person(actor, "usr_other"), actor, person(elsewhere)] do
        assert {:error, :not_live} = FrameCredentials.consume(stranger, row.frame_id, @digest)
      end

      assert FrameCredentials.get(actor, row.id) == {:ok, row}

      {:ok, revoked} = FrameCredentials.revoke(actor, row.id)
      assert {:error, :not_live} = FrameCredentials.consume(person(actor), row.frame_id, @digest)
      assert FrameCredentials.get(actor, row.id) == {:ok, revoked}

      assert {:error, :not_live} = FrameCredentials.consume(person(actor), "frm_absent", @digest)

      assert {:error, :no_athanor} =
               FrameCredentials.consume(Prima.Actor.system(), row.frame_id, @digest)
    end

    test "a wrong digest changes nothing, and the right one then spends the row", %{
      actor: actor
    } do
      row = mint!(actor, %{purpose: "validation"})
      wrong = "sha256:" <> String.duplicate("b", 64)

      assert {:error, :not_live} = FrameCredentials.consume(person(actor), row.frame_id, wrong)
      assert FrameCredentials.get(actor, row.id) == {:ok, row}

      assert {:ok, %{state: "revoked"}} =
               FrameCredentials.consume(person(actor), row.frame_id, @digest)
    end

    test "a stale owner spends nothing", %{actor: actor, slot: slot} do
      row = mint!(actor, %{purpose: "validation"})
      take_over!(slot)

      assert {:error, :not_owner} = FrameCredentials.consume(person(actor), row.frame_id, @digest)
      assert FrameCredentials.get(actor, row.id) == {:ok, row}
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
