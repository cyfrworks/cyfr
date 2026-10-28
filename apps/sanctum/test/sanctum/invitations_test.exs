# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.InvitationsTest do
  @moduledoc """
  Who may issue, revoke and list invitations, and what the invitation page
  reads of one (`Sanctum.Invitations`).

  The platform administrator issues one naming no athanor; anyone issues
  one naming a group athanor they hold a seat in, the administrator
  included, and to anyone else that athanor answers as a missing one. The
  code is given once and only its hash is stored. The issuer or the
  administrator revokes; the administrator lists every invitation and
  anyone else their own. `lookup/1` names who invited and to which
  athanor, never by an address, and refuses an expired, redeemed or
  revoked code, and one whose issuer lost the seat or was denied, with one
  answer.
  """

  # Contexts are loaded from sessions, and the caps' settings are
  # process-wide.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.Invitation
  alias Sanctum.Invitations
  alias Sanctum.Tenancy.{Athanors, Members, Users}
  alias Sanctum.TestContext

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp person!(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(
        Map.merge(
          %{
            id: "github|https://github.com|invitations-#{n}",
            provider: "github",
            email: "invitations-#{n}@example.com",
            verified: true
          },
          attrs
        )
      )

    user
  end

  defp admin! do
    user = person!()
    {:ok, _row} = TestContext.ensure_platform(user.id)
    user
  end

  defp ctx(user), do: TestContext.session!(user.id)

  defp group!(creator, members \\ []) do
    {:ok, group} =
      Athanors.create_group(creator.id, "Invited #{System.unique_integer([:positive])}")

    for member <- members,
        do: {:ok, :added} = Members.add(group, [user_id: member.id], creator.id)

    group
  end

  defp row(id), do: Arca.Repo.get!(Invitation, id)
  defp invitations, do: Arca.Repo.aggregate(Invitation, :count)

  defp expire!(id) do
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    {1, _} =
      Arca.Repo.update_all(from(i in Invitation, where: i.id == ^id), set: [expires_at: past])
  end

  describe "create/2" do
    test "a member issues one for their group: the code is given once and only its hash is stored" do
      alice = person!()
      group = group!(alice)
      before = DateTime.utc_now()

      assert {:ok, %{invitation: invitation, code: code}} =
               Invitations.create(ctx(alice), group.id)

      assert {:ok, <<_::binary-size(32)>> = bytes} = Base.url_decode64(code, padding: false)
      refute code =~ "="

      assert %{
               id: id,
               state: "pending",
               issued_by: issued_by,
               athanor_id: athanor_id,
               athanor_name: name,
               expires_at: expires_at
             } = invitation

      assert {issued_by, athanor_id, name} == {alice.id, group.id, group.name}
      assert DateTime.diff(expires_at, before, :day) in [6, 7]

      stored = row(id)
      assert stored.code_hash == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      refute Enum.any?(Map.values(Map.from_struct(stored)), &(&1 == code))
    end

    test "the administrator issues one naming no athanor; it carries no athanor key" do
      admin = admin!()

      assert {:ok, %{invitation: invitation}} = Invitations.create(ctx(admin), nil)
      assert invitation.state == "pending"
      refute Map.has_key?(invitation, :athanor_id)
      refute Map.has_key?(invitation, :athanor_name)
      assert row(invitation.id).athanor_id == nil
    end

    test "a member cannot issue one naming no athanor, and a non-member cannot issue for a group" do
      alice = person!()
      outsider = person!()
      group = group!(alice)

      assert {:error, :platform_admin_required} = Invitations.create(ctx(alice), nil)

      assert {:error, {:not_found, "Athanor", id}} = Invitations.create(ctx(outsider), group.id)
      assert id == group.id

      assert {:error, {:not_found, "Athanor", "ath_missing"}} =
               Invitations.create(ctx(outsider), "ath_missing")

      assert invitations() == 0
    end

    test "the administrator issues for a group only from a seat in it" do
      admin = admin!()
      alice = person!()
      group = group!(alice)

      assert {:error, {:not_found, "Athanor", _}} = Invitations.create(ctx(admin), group.id)
      assert invitations() == 0

      {:ok, :added} = Members.add(group, [user_id: admin.id], alice.id)
      assert {:ok, _} = Invitations.create(ctx(admin), group.id)
    end

    test "a person's own athanor, a frozen pair and an archived group take none" do
      alice = person!()
      bob = person!()
      shared = group!(alice, [bob])
      own = Sanctum.Test.People.athanor!(alice)
      {:ok, pair} = Athanors.create_pair(alice.id, bob.id)
      archived = group!(alice, [bob])
      {:ok, _} = Athanors.archive(archived)

      for athanor <- [own, pair, archived] do
        assert {:error, {:invalid_argument, _}} = Invitations.create(ctx(alice), athanor.id)
      end

      assert invitations() == 0
      assert {:ok, _} = Invitations.create(ctx(alice), shared.id)
    end
  end

  describe "revoke/2" do
    test "the issuer revokes; another member is answered as if it were missing; the administrator revokes anyone's" do
      admin = admin!()
      alice = person!()
      bob = person!()
      group = group!(alice, [bob])
      {:ok, %{invitation: first}} = Invitations.create(ctx(alice), group.id)
      {:ok, %{invitation: second}} = Invitations.create(ctx(alice), group.id)

      assert {:error, {:not_found, "Invitation", _}} = Invitations.revoke(ctx(bob), first.id)
      assert row(first.id).revoked_at == nil

      assert {:ok, %{state: "revoked"}} = Invitations.revoke(ctx(alice), first.id)
      assert {:ok, %{state: "revoked"}} = Invitations.revoke(ctx(admin), second.id)
      assert %DateTime{} = row(second.id).revoked_at

      assert {:error, {:not_found, "Invitation", "inv_missing"}} =
               Invitations.revoke(ctx(alice), "inv_missing")
    end

    test "a redeemed invitation cannot be revoked" do
      alice = person!()
      group = group!(alice)
      {:ok, %{invitation: invitation, code: code}} = Invitations.create(ctx(alice), group.id)
      {:ok, _} = Invitations.redeem(code, person!().id)

      assert {:error, {:invalid_argument, _}} = Invitations.revoke(ctx(alice), invitation.id)
      assert row(invitation.id).revoked_at == nil
    end
  end

  describe "list/1" do
    test "the administrator sees every invitation, anyone else their own, each with its state" do
      admin = admin!()
      alice = person!()
      bob = person!()
      group = group!(alice, [bob])

      {:ok, %{invitation: pending}} = Invitations.create(ctx(alice), group.id)
      {:ok, %{invitation: revoked}} = Invitations.create(ctx(alice), group.id)
      {:ok, _} = Invitations.revoke(ctx(alice), revoked.id)
      {:ok, %{invitation: expired}} = Invitations.create(ctx(alice), group.id)
      expire!(expired.id)
      {:ok, %{invitation: redeemed, code: code}} = Invitations.create(ctx(alice), group.id)
      {:ok, _} = Invitations.redeem(code, person!().id)
      {:ok, %{invitation: bobs}} = Invitations.create(ctx(bob), group.id)
      {:ok, %{invitation: admins}} = Invitations.create(ctx(admin), nil)

      states = fn ctx ->
        {:ok, listed} = Invitations.list(ctx)
        Map.new(listed, &{&1.id, &1.state})
      end

      assert states.(ctx(alice)) == %{
               pending.id => "pending",
               revoked.id => "revoked",
               expired.id => "expired",
               redeemed.id => "redeemed"
             }

      assert states.(ctx(bob)) == %{bobs.id => "pending"}

      everyone = states.(ctx(admin))
      assert Map.take(everyone, [pending.id, bobs.id, admins.id]) |> map_size() == 3

      # The administrator holds no seat in the group: its id is shown, its
      # name is not.
      {:ok, listed} = Invitations.list(ctx(admin))
      shown = Enum.find(listed, &(&1.id == bobs.id))
      assert shown.athanor_id == group.id
      refute Map.has_key?(shown, :athanor_name)
      refute Map.has_key?(Enum.find(listed, &(&1.id == admins.id)), :athanor_id)
    end
  end

  describe "lookup/1" do
    test "names who invited and to which athanor, and the expiry" do
      alice = person!(%{name: "Alice Example"})
      group = group!(alice)
      {:ok, %{invitation: invitation, code: code}} = Invitations.create(ctx(alice), group.id)

      assert {:ok, shown} = Invitations.lookup(code)

      assert shown == %{
               inviter: "Alice Example",
               athanor: group.name,
               expires_at: invitation.expires_at
             }
    end

    test "names the inviter by their handle without a display name, else neutrally, never by address" do
      handled = person!()

      {:ok, handled} =
        Users.set_namespace(handled, "handled#{System.unique_integer([:positive])}")

      plain = person!()
      admin = admin!()

      for {issuer, expected} <- [
            {handled, "@" <> handled.namespace},
            {plain, "a member of this CYFR"}
          ] do
        {:ok, %{code: code}} = Invitations.create(ctx(issuer), group!(issuer).id)
        assert {:ok, %{inviter: ^expected}} = Invitations.lookup(code)
        refute expected =~ "@example.com"
      end

      {:ok, %{code: code}} = Invitations.create(ctx(admin), nil)
      assert {:ok, shown} = Invitations.lookup(code)
      assert shown.inviter == "a member of this CYFR"
      refute Map.has_key?(shown, :athanor)
    end

    test "an expired, a redeemed, a revoked, an unknown and a malformed code are one refusal" do
      alice = person!()
      group = group!(alice)
      {:ok, %{invitation: expired, code: expired_code}} = Invitations.create(ctx(alice), group.id)
      expire!(expired.id)
      {:ok, %{code: redeemed_code}} = Invitations.create(ctx(alice), group.id)
      {:ok, _} = Invitations.redeem(redeemed_code, person!().id)
      {:ok, %{invitation: revoked, code: revoked_code}} = Invitations.create(ctx(alice), group.id)
      {:ok, _} = Invitations.revoke(ctx(alice), revoked.id)
      unknown = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      for code <- [expired_code, redeemed_code, revoked_code, unknown, "not a code", "", nil] do
        assert {:error, :invitation_invalid} = Invitations.lookup(code)
        assert {:error, :invitation_invalid} = Invitations.redeemable(code)
      end
    end

    test "an issuer who lost their seat, and one who was denied, admit no one" do
      alice = person!()
      bob = person!()
      group = group!(alice, [bob])
      {:ok, %{code: left}} = Invitations.create(ctx(bob), group.id)
      {:ok, %{code: denied}} = Invitations.create(ctx(alice), group.id)
      assert {:ok, _} = Invitations.lookup(left)
      assert {:ok, _} = Invitations.lookup(denied)

      :ok = Members.remove_member(group, user_id: bob.id)
      {:ok, _} = Users.deny(alice)

      for code <- [left, denied] do
        assert {:error, :invitation_invalid} = Invitations.lookup(code)
        assert {:error, :invitation_invalid} = Invitations.redeemable(code)
      end
    end

    test "a group archived since, and an issuer of one naming no athanor who no longer administers, admit no one" do
      admin = admin!()
      alice = person!()
      group = group!(alice, [person!()])
      {:ok, %{code: archived}} = Invitations.create(ctx(alice), group.id)
      {:ok, %{code: platform}} = Invitations.create(ctx(admin), nil)

      {:ok, _} = Athanors.archive(group)
      {:ok, seat} = Members.platform_seat(admin.id)
      {1, _} = Arca.Repo.delete_all(from(m in Arca.Schemas.Membership, where: m.id == ^seat.id))

      for code <- [archived, platform] do
        assert {:error, :invitation_invalid} = Invitations.lookup(code)
      end
    end
  end
end
