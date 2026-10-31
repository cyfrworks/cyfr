# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.InvitationsTest do
  @moduledoc """
  Invitations to become a person here: written in the actor's athanor, or
  in none under the platform scope, by the hash of their code with an
  expiry on the database's clock, the issuer's generation as their row
  stands and the name offered, if any; found by that hash and listed across
  athanors only under the platform scope; ended once, revoked while open
  or redeemed while open and unexpired, each by one conditional write. An
  athanor's erasure takes the invitations that name it and leaves the
  instance's own.
  """

  use ExUnit.Case, async: true

  import Ecto.Query, only: [from: 2]

  alias Arca.Invitations
  alias Arca.Schemas.Invitation

  @day_ms 24 * 60 * 60 * 1000

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    athanor = "ath_inv_#{System.unique_integer([:positive])}"
    {:ok, athanor: athanor, actor: Prima.Actor.in_athanor(athanor)}
  end

  defp server, do: Prima.Actor.system()
  defp person, do: "usr_inv_#{System.unique_integer([:positive])}"
  defp code_hash, do: Prima.Digest.sha256_hex(:crypto.strong_rand_bytes(32))

  # A person's row, as an invitation's issuer has one.
  defp issuer! do
    now = DateTime.utc_now()

    {:ok, user} =
      Arca.Test.People.mint(
        server(),
        %{
          id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        },
        nil
      )

    user.id
  end

  defp issued!(actor, issuer \\ issuer!()) do
    hash = code_hash()

    {:ok, row} =
      Invitations.insert(actor, %{code_hash: hash, issued_by: issuer, lifetime_ms: 7 * @day_ms})

    {row, hash}
  end

  # An also: closure that says it ran.
  defp ran(test) do
    send(test, :also_ran)
    :ok
  end

  defp expire!(id) do
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    {1, _} =
      Arca.Repo.update_all(from(i in Invitation, where: i.id == ^id), set: [expires_at: past])
  end

  describe "insert/2" do
    test "names the actor's athanor, or none under the platform scope, and sets the expiry from the lifetime",
         %{actor: actor, athanor: athanor} do
      issuer = issuer!()
      before = DateTime.utc_now()
      {row, hash} = issued!(actor, issuer)

      assert %{
               id: "inv_" <> _,
               code_hash: ^hash,
               issued_by: ^issuer,
               athanor_id: ^athanor,
               name: nil,
               redeemed_by: nil,
               redeemed_at: nil,
               revoked_at: nil
             } = row

      lifetime = DateTime.diff(row.expires_at, row.inserted_at, :millisecond)
      assert lifetime == 7 * @day_ms
      assert DateTime.compare(row.inserted_at, before) != :lt

      {platform, _hash} = issued!(server())
      assert platform.athanor_id == nil
    end

    test "takes the athanor from the actor alone, and refuses an actor with none", %{actor: actor} do
      {:ok, row} =
        Invitations.insert(actor, %{
          code_hash: code_hash(),
          issued_by: issuer!(),
          lifetime_ms: @day_ms,
          athanor_id: "ath_elsewhere"
        })

      assert row.athanor_id == actor.athanor_id

      assert {:error, :no_athanor} =
               Invitations.insert(%Prima.Actor{scope: :athanor}, %{
                 code_hash: code_hash(),
                 issued_by: issuer!(),
                 lifetime_ms: @day_ms
               })
    end

    test "keeps the name it offers its newcomer", %{actor: actor} do
      attrs = %{code_hash: code_hash(), issued_by: issuer!(), lifetime_ms: @day_ms, name: "mira"}
      {:ok, row} = Invitations.insert(actor, attrs)

      assert row.name == "mira"
      assert {:ok, %{name: "mira"}} = Invitations.by_code_hash(server(), attrs.code_hash)
    end

    test "refuses a malformed row and a code hash already taken", %{actor: actor} do
      assert {:error, {:invalid, errors}} =
               Invitations.insert(actor, %{
                 code_hash: "NOT-HEX",
                 issued_by: "system",
                 lifetime_ms: 0,
                 name: ""
               })

      assert Map.keys(errors) |> Enum.sort() == [:code_hash, :issued_by, :lifetime_ms, :name]

      {_row, hash} = issued!(actor)

      assert {:error, :conflict} =
               Invitations.insert(actor, %{code_hash: hash, issued_by: issuer!(), lifetime_ms: 1})

      assert Arca.Repo.aggregate(from(i in Invitation, where: i.code_hash == ^hash), :count) == 1
    end

    test "records the issuer's generation as their row stands, and refuses an issuer naming no person here",
         %{actor: actor} do
      issuer = issuer!()
      {first, _hash} = issued!(actor, issuer)
      assert first.issuer_generation == 1

      {1, _} =
        Arca.Repo.update_all(from(u in Arca.Schemas.User, where: u.id == ^issuer),
          inc: [security_generation: 1]
        )

      {second, _hash} = issued!(server(), issuer)
      assert second.issuer_generation == 2
      assert {:ok, %{issuer_generation: 1}} = Invitations.get(server(), first.id)

      before = Arca.Repo.aggregate(Invitation, :count)

      assert {:error, {:invalid, %{issued_by: _}}} =
               Invitations.insert(actor, %{
                 code_hash: code_hash(),
                 issued_by: person(),
                 lifetime_ms: @day_ms
               })

      assert Arca.Repo.aggregate(Invitation, :count) == before
    end
  end

  describe "the reads" do
    test "find an invitation by id and by code hash, and list all or an issuer's, newest first",
         %{actor: actor} do
      issuer = issuer!()
      {first, first_hash} = issued!(actor, issuer)
      {second, _} = issued!(server(), issuer)
      {other, _} = issued!(actor)

      assert {:ok, ^first} = Invitations.get(server(), first.id)
      assert {:ok, ^first} = Invitations.by_code_hash(server(), first_hash)
      assert {:error, :not_found} = Invitations.get(server(), "inv_missing")
      assert {:error, :not_found} = Invitations.by_code_hash(server(), code_hash())

      assert {:ok, mine} = Invitations.list(server(), issued_by: issuer)
      assert Enum.map(mine, & &1.id) == [second.id, first.id]

      assert {:ok, all} = Invitations.list(server(), [])
      assert Enum.all?([first.id, second.id, other.id], &(&1 in Enum.map(all, fn r -> r.id end)))
    end

    test "every function but insert refuses an athanor-scoped actor", %{actor: actor} do
      {row, hash} = issued!(actor)

      assert {:error, :cross_tenant} = Invitations.get(actor, row.id)
      assert {:error, :cross_tenant} = Invitations.by_code_hash(actor, hash)
      assert {:error, :cross_tenant} = Invitations.list(actor, [])
      assert {:error, :cross_tenant} = Invitations.revoke(actor, row.id)
      assert {:error, :cross_tenant} = Invitations.redeem(actor, hash, person())
      assert {:ok, %{revoked_at: nil, redeemed_at: nil}} = Invitations.get(server(), row.id)
    end
  end

  describe "revoke/2" do
    test "ends an open invitation once, answers a revoked one as it stands, and refuses a redeemed one",
         %{actor: actor} do
      {row, _hash} = issued!(actor)

      assert {:ok, %{revoked_at: %DateTime{} = at}} = Invitations.revoke(server(), row.id)
      assert {:ok, %{revoked_at: ^at}} = Invitations.revoke(server(), row.id)

      {redeemed, hash} = issued!(actor)
      {:ok, _} = Invitations.redeem(server(), hash, person())
      assert {:error, :redeemed} = Invitations.revoke(server(), redeemed.id)
      assert {:ok, %{revoked_at: nil}} = Invitations.get(server(), redeemed.id)

      assert {:error, :not_found} = Invitations.revoke(server(), "inv_missing")
    end
  end

  describe "redeem/3" do
    test "marks an open invitation redeemed by the person once", %{actor: actor} do
      {row, hash} = issued!(actor)
      newcomer = person()

      assert {:ok, %{id: id, redeemed_by: ^newcomer, redeemed_at: %DateTime{}}} =
               Invitations.redeem(server(), hash, newcomer)

      assert id == row.id
      assert {:error, :not_found} = Invitations.redeem(server(), hash, person())
      assert {:ok, %{redeemed_by: ^newcomer}} = Invitations.get(server(), row.id)
    end

    test "marks no revoked, expired or unknown invitation", %{actor: actor} do
      {revoked, revoked_hash} = issued!(actor)
      {:ok, _} = Invitations.revoke(server(), revoked.id)

      {expired, expired_hash} = issued!(actor)
      expire!(expired.id)

      for hash <- [revoked_hash, expired_hash, code_hash()] do
        assert {:error, :not_found} = Invitations.redeem(server(), hash, person())
      end

      for id <- [revoked.id, expired.id] do
        assert {:ok, %{redeemed_by: nil, redeemed_at: nil}} = Invitations.get(server(), id)
      end
    end
  end

  describe "redeem_for/4" do
    test "redeems in a transaction of its own and hands also: the redeemed row", %{actor: actor} do
      {row, hash} = issued!(actor)
      redeemer = person()
      test = self()

      assert {:ok, %{id: id, redeemed_by: ^redeemer} = redeemed} =
               Invitations.redeem_for(server(), hash, redeemer,
                 also: fn handed ->
                   send(test, {:handed, handed, Arca.in_transaction?()})
                   :ok
                 end
               )

      assert id == row.id
      assert_received {:handed, ^redeemed, true}
      assert %Invitation{redeemed_by: ^redeemer} = Arca.Repo.get!(Invitation, row.id)
    end

    test "an also: refusal rolls the redemption back, leaving the invitation open", %{
      actor: actor
    } do
      {row, hash} = issued!(actor)

      assert {:error, :refused_above} =
               Invitations.redeem_for(server(), hash, person(),
                 also: fn _row -> {:error, :refused_above} end
               )

      assert %Invitation{redeemed_by: nil, redeemed_at: nil} = Arca.Repo.get!(Invitation, row.id)
    end

    test "marks no revoked, expired, redeemed or unknown invitation, and runs no also:", %{
      actor: actor
    } do
      {revoked, revoked_hash} = issued!(actor)
      {:ok, _} = Invitations.revoke(server(), revoked.id)
      {expired, expired_hash} = issued!(actor)
      expire!(expired.id)
      {_redeemed, redeemed_hash} = issued!(actor)
      {:ok, _} = Invitations.redeem(server(), redeemed_hash, person())
      test = self()
      also = fn _row -> ran(test) end

      for hash <- [revoked_hash, expired_hash, redeemed_hash, code_hash()] do
        assert {:error, :not_found} = Invitations.redeem_for(server(), hash, person(), also: also)
      end

      refute_received :also_ran
    end

    test "an athanor-scoped actor is refused before anything runs", %{actor: actor} do
      {row, hash} = issued!(actor)
      test = self()

      assert {:error, :cross_tenant} =
               Invitations.redeem_for(actor, hash, person(), also: fn _row -> ran(test) end)

      refute_received :also_ran
      assert %Invitation{redeemed_by: nil} = Arca.Repo.get!(Invitation, row.id)
    end
  end

  test "an athanor's erasure takes the invitations naming it and leaves the instance's own", %{
    actor: actor
  } do
    {named, _} = issued!(actor)
    {own, _} = issued!(server())

    assert {:ok, %{"invitations" => 1}} = Arca.TenantTables.delete_all_for(actor)
    assert {:error, :not_found} = Invitations.get(server(), named.id)
    assert {:ok, _} = Invitations.get(server(), own.id)
  end
end

defmodule Arca.InvitationsOwnerTest do
  @moduledoc """
  A redemption for a person who already exists writes only while this
  member holds its slot: once another member has taken it, `redeem_for/4`
  is refused `:not_owner`, runs no `also:`, and the invitation stays open.
  """

  # Takes the cell's slot, which is process-wide; the case restores it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{ControlPlane, Invitations}
  alias Arca.Schemas.{CellLease, Invitation}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    for key <- [
          {Arca.ControlPlane, :standing},
          {Arca.ControlPlane, :generation},
          {Arca.ControlPlane, :slot}
        ],
        do: Prima.Test.Env.erase_persistent_term(key)

    Prima.Test.Env.put_app_env(:arca, :control_plane_claim_enabled, true)
    node = "invitations-owner-#{System.unique_integer([:positive])}"
    {:ok, slot} = ControlPlane.take(node, node <> "#boot", 60_000)
    {:ok, slot: slot}
  end

  defp server, do: Prima.Actor.system()

  defp ran(test) do
    send(test, :also_ran)
    :ok
  end

  defp issued! do
    now = DateTime.utc_now()

    {:ok, issuer} =
      Arca.Test.People.mint(
        server(),
        %{
          id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        },
        nil
      )

    hash = Prima.Digest.sha256_hex(:crypto.strong_rand_bytes(32))

    {:ok, row} =
      Invitations.insert(server(), %{
        code_hash: hash,
        issued_by: issuer.id,
        lifetime_ms: 24 * 60 * 60 * 1000
      })

    {row, hash}
  end

  test "a member whose slot another took redeems nothing and runs no also:", %{slot: slot} do
    {row, hash} = issued!()
    test = self()

    {1, _} =
      Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
        set: [owner: "someone-else", generation: slot.generation + 1]
      )

    assert {:error, :not_owner} =
             Invitations.redeem_for(server(), hash, "usr_stale", also: fn _row -> ran(test) end)

    refute_received :also_ran
    assert %Invitation{redeemed_by: nil, redeemed_at: nil} = Arca.Repo.get!(Invitation, row.id)
  end
end
