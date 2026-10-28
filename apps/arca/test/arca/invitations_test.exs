# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.InvitationsTest do
  @moduledoc """
  Invitations to become a person here: written in the actor's athanor, or
  in none under the platform scope, by the hash of their code with an
  expiry on the database's clock; found by that hash and listed across
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

  defp issued!(actor, issuer \\ person()) do
    hash = code_hash()

    {:ok, row} =
      Invitations.insert(actor, %{code_hash: hash, issued_by: issuer, lifetime_ms: 7 * @day_ms})

    {row, hash}
  end

  defp expire!(id) do
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    {1, _} =
      Arca.Repo.update_all(from(i in Invitation, where: i.id == ^id), set: [expires_at: past])
  end

  describe "insert/2" do
    test "names the actor's athanor, or none under the platform scope, and sets the expiry from the lifetime",
         %{actor: actor, athanor: athanor} do
      issuer = person()
      before = DateTime.utc_now()
      {row, hash} = issued!(actor, issuer)

      assert %{
               id: "inv_" <> _,
               code_hash: ^hash,
               issued_by: ^issuer,
               athanor_id: ^athanor,
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
          issued_by: person(),
          lifetime_ms: @day_ms,
          athanor_id: "ath_elsewhere"
        })

      assert row.athanor_id == actor.athanor_id

      assert {:error, :no_athanor} =
               Invitations.insert(%Prima.Actor{scope: :athanor}, %{
                 code_hash: code_hash(),
                 issued_by: person(),
                 lifetime_ms: @day_ms
               })
    end

    test "refuses a malformed row and a code hash already taken", %{actor: actor} do
      assert {:error, {:invalid, errors}} =
               Invitations.insert(actor, %{
                 code_hash: "NOT-HEX",
                 issued_by: "system",
                 lifetime_ms: 0
               })

      assert Map.keys(errors) |> Enum.sort() == [:code_hash, :issued_by, :lifetime_ms]

      {_row, hash} = issued!(actor)

      assert {:error, :conflict} =
               Invitations.insert(actor, %{code_hash: hash, issued_by: person(), lifetime_ms: 1})

      assert Arca.Repo.aggregate(from(i in Invitation, where: i.code_hash == ^hash), :count) == 1
    end
  end

  describe "the reads" do
    test "find an invitation by id and by code hash, and list all or an issuer's, newest first",
         %{actor: actor} do
      issuer = person()
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
