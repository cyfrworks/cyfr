# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.InvitationsTest do
  @moduledoc """
  Who may issue, revoke and list invitations, and what the invitation page
  reads of one (`Sanctum.Invitations`).

  The platform administrator issues one naming no athanor; anyone issues
  one naming a group athanor they hold a seat in, the administrator
  included, and to anyone else that athanor answers as a missing one. One
  may offer its newcomer a name, which the invitation page reads. The
  code is given once and only its hash is stored. The issuer or the
  administrator revokes; the administrator lists every invitation and
  anyone else their own. `lookup/1` names who invited and to which
  athanor, never by an address, and refuses an expired, redeemed or
  revoked code, and one whose issuer lost the seat or was denied, with one
  answer. `redeemable_hash/1` makes the same checks from the code's hash.
  `redeem_for/2` redeems one for a person this CYFR knows, writing their
  seat and their identifier's allow with the redemption, once, and a deny
  rolls all of it back with the invitation unspent.
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

  defp hash(code) do
    {:ok, hash} = Invitations.code_hash(code)
    hash
  end

  # A person whose keys another CYFR holds, known here by their identifier.
  defp remote!(name \\ nil) do
    n = System.unique_integer([:positive])
    identifier = "per_" <> Prima.Digest.sha256_hex("invitations-remote-#{n}")

    {:ok, user} =
      Sanctum.Test.People.remote(
        %{
          id: Sanctum.Auth.Identity.cyfr_key("https://dir.example", identifier),
          provider: "cyfr"
        },
        %{identifier: identifier, directory_url: "https://dir.example"}
      )

    if name, do: {:ok, _} = Arca.Users.update(Prima.Actor.system(), user.id, %{namespace: name})
    Map.put(user, :identifier, identifier)
  end

  defp door(identifier),
    do: Enum.filter(Sanctum.Door.Store.list(), &(&1.value == identifier))

  defp seated?(user, group), do: Members.member?(user.id, group.id)
  defp invitations, do: Arca.Repo.aggregate(Invitation, :count)

  defp expire!(id) do
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    {1, _} =
      Arca.Repo.update_all(from(i in Invitation, where: i.id == ^id), set: [expires_at: past])
  end

  describe "create/3" do
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

    test "offers the newcomer a name the invitation page reads, and refuses one that is no name" do
      alice = person!()
      group = group!(alice)

      assert {:ok, %{invitation: invitation, code: code}} =
               Invitations.create(ctx(alice), group.id, "mira")

      assert row(invitation.id).name == "mira"
      assert {:ok, %{name: "mira"}} = Invitations.lookup(code)

      before = invitations()

      for name <- ["Not A Name", "", "-mira", String.duplicate("a", 40)] do
        assert {:error, {:invalid_argument, _}} =
                 Invitations.create(ctx(alice), group.id, name),
               inspect(name)
      end

      assert invitations() == before
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

    test "redeemable_hash/1 agrees with redeemable/1, and refuses what is no hash" do
      alice = person!()
      bob = person!()
      group = group!(alice, [bob])
      {:ok, %{code: open}} = Invitations.create(ctx(alice), group.id)
      {:ok, %{code: left}} = Invitations.create(ctx(bob), group.id)
      {:ok, %{invitation: expired, code: expired_code}} = Invitations.create(ctx(alice), group.id)
      expire!(expired.id)
      {:ok, %{invitation: revoked, code: revoked_code}} = Invitations.create(ctx(alice), group.id)
      {:ok, _} = Invitations.revoke(ctx(alice), revoked.id)
      {:ok, %{code: redeemed_code}} = Invitations.create(ctx(alice), group.id)
      {:ok, _} = Invitations.redeem(redeemed_code, person!().id)
      :ok = Members.remove_member(group, user_id: bob.id)

      assert :ok = Invitations.redeemable(open)
      assert :ok = Invitations.redeemable_hash(hash(open))

      for code <- [left, expired_code, revoked_code, redeemed_code] do
        assert {:error, :invitation_invalid} = Invitations.redeemable(code)
        assert {:error, :invitation_invalid} = Invitations.redeemable_hash(hash(code))
      end

      for value <- [open, String.upcase(hash(open)), "", nil, 7, hash(open) <> "0"] do
        assert {:error, :invitation_invalid} = Invitations.redeemable_hash(value)
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

  describe "redeem_for/2" do
    test "a known person's redemption writes nothing after this member loses its slot" do
      alice = person!()
      group = group!(alice)
      carol = remote!()
      {:ok, %{invitation: invitation, code: code}} = Invitations.create(ctx(alice), group.id)

      keys = [
        {Arca.ControlPlane, :standing},
        {Arca.ControlPlane, :generation},
        {Arca.ControlPlane, :slot}
      ]

      for key <- keys, do: Prima.Test.Env.erase_persistent_term(key)
      Prima.Test.Env.put_app_env(:arca, :control_plane_claim_enabled, true)
      node = "invitation-stale-#{System.unique_integer([:positive])}"
      {:ok, slot} = Arca.ControlPlane.take(node, node <> "#old", 60_000)

      {1, _} =
        Arca.Repo.update_all(from(l in Arca.Schemas.CellLease, where: l.node == ^slot.node),
          set: [owner: "successor", generation: slot.generation + 1]
        )

      assert :lost = Arca.ControlPlane.check_held(slot)
      answer = Invitations.redeem_for(hash(code), carol.id)

      actual = %{
        redeemed_by: row(invitation.id).redeemed_by,
        seated: seated?(carol, group),
        door: Enum.map(door(carol.identifier), & &1.effect)
      }

      assert actual == %{redeemed_by: nil, seated: false, door: []},
             "a stale owner changed admission state: #{inspect(actual)}; answer=#{inspect(answer)}"
    end

    test "redeems once for a person known here, writing their seat and their identifier's allow" do
      alice = person!()
      group = group!(alice)
      carol = remote!("carol")
      {:ok, %{invitation: invitation, code: code}} = Invitations.create(ctx(alice), group.id)
      note = "invitation " <> invitation.id

      assert {:ok, %{redeemed_by: redeemed_by}} = Invitations.redeem_for(hash(code), carol.id)
      assert redeemed_by == carol.id
      assert seated?(carol, group)

      assert [
               %{
                 kind: "identifier",
                 effect: "allow",
                 status: "allowed",
                 added_by: added_by,
                 note: ^note,
                 label: "carol"
               }
             ] = door(carol.identifier)

      assert added_by == alice.id

      # Once: a second redemption, by anyone, finds it used and writes nothing.
      dave = remote!()
      assert {:error, :invitation_invalid} = Invitations.redeem_for(hash(code), dave.id)
      assert {:error, :invitation_invalid} = Invitations.redeem_for(hash(code), carol.id)
      refute seated?(dave, group)
      assert door(dave.identifier) == []
      assert length(door(carol.identifier)) == 1
    end

    test "one naming no athanor writes the allow and no seat" do
      admin = admin!()
      carol = remote!()
      {:ok, %{code: code}} = Invitations.create(ctx(admin), nil)

      assert {:ok, _} = Invitations.redeem_for(hash(code), carol.id)
      assert [%{effect: "allow", label: nil}] = door(carol.identifier)
      assert {:ok, []} = Members.list_by_user(carol.id)
    end

    test "a deny of the identifier or of the person refuses it, the invitation unspent and no seat" do
      alice = person!()
      group = group!(alice)
      carol = remote!()
      dave = remote!()
      {:ok, %{invitation: invitation, code: code}} = Invitations.create(ctx(alice), group.id)
      {:ok, identifier_deny} = Sanctum.Door.Store.deny("identifier", carol.identifier, "ops")
      {:ok, _person_deny} = Sanctum.Door.Store.deny("person", dave.id, "ops")

      assert {:error, {:door, :denied}} = Invitations.redeem_for(hash(code), carol.id)
      assert {:error, {:door, :denied}} = Invitations.redeem_for(hash(code), dave.id)

      assert %{redeemed_at: nil, redeemed_by: nil} = row(invitation.id)
      refute seated?(carol, group)
      refute seated?(dave, group)
      assert door(carol.identifier) == [identifier_deny]
      assert door(dave.identifier) == []
      assert :ok = Invitations.redeemable(code)
    end

    test "a spent, revoked or expired invitation writes no seat and no allow" do
      alice = person!()
      group = group!(alice)
      {:ok, %{code: spent}} = Invitations.create(ctx(alice), group.id)
      {:ok, _} = Invitations.redeem(spent, person!().id)
      {:ok, %{invitation: revoked, code: revoked_code}} = Invitations.create(ctx(alice), group.id)
      {:ok, _} = Invitations.revoke(ctx(alice), revoked.id)
      {:ok, %{invitation: expired, code: expired_code}} = Invitations.create(ctx(alice), group.id)
      expire!(expired.id)

      for code <- [spent, revoked_code, expired_code] do
        carol = remote!()
        assert {:error, :invitation_invalid} = Invitations.redeem_for(hash(code), carol.id)
        refute seated?(carol, group)
        assert door(carol.identifier) == []
      end
    end

    test "a group's member cap, reached, refuses it and rolls the redemption back" do
      alice = person!()
      group = group!(alice)
      carol = remote!()
      {:ok, %{invitation: invitation, code: code}} = Invitations.create(ctx(alice), group.id)
      Sanctum.Test.Settings.put("max_members_per_group", 1)

      assert {:error, {:limit_reached, :max_members_per_group, 1}} =
               Invitations.redeem_for(hash(code), carol.id)

      assert %{redeemed_at: nil} = row(invitation.id)
      assert door(carol.identifier) == []
    end
  end
end

defmodule Sanctum.InvitationsRaceTest do
  @moduledoc """
  A deny that commits on another connection while a known person's
  redemption runs: after the caller's check of the door and before the
  redemption's write, and, on PostgreSQL, inside the redemption's
  transaction before its allow. Either way the deny wins: the redemption
  rolls back with the invitation unspent, no seat and no allow.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Arca.Test.Adapter, only: [postgres?: 0]

  alias Arca.Schemas.{Athanor, ExternalIdentity, Invitation, Membership, PersonIdentity, User}
  alias Arca.Schemas.ServerAllowlistEntry, as: Entry
  alias Ecto.Adapters.SQL.Sandbox
  alias Sanctum.Door.Store
  alias Sanctum.Invitations

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  setup do
    n = System.unique_integer([:positive])
    key = "github|https://github.com|invitations-race-#{n}"
    identifier = "per_" <> Prima.Digest.sha256_hex("invitations-race-#{n}")
    remote_key = Sanctum.Auth.Identity.cyfr_key("https://dir.example", identifier)
    on_exit(fn -> unboxed(fn -> cleanup!([key, remote_key], identifier) end) end)

    unboxed(fn ->
      {:ok, issuer} = Sanctum.Test.People.linked(%{id: key, provider: "github"})
      {:ok, group} = Sanctum.Tenancy.Athanors.create_group(issuer.id, "Race #{n}")
      ctx = Sanctum.Context.build(user_id: issuer.id)
      {:ok, %{invitation: invitation, code: code}} = Invitations.create(ctx, group.id)
      {:ok, hash} = Invitations.code_hash(code)

      {:ok, carol} =
        Sanctum.Test.People.remote(%{id: remote_key, provider: "cyfr"}, %{
          identifier: identifier,
          directory_url: "https://dir.example"
        })

      {:ok,
       group: group, invitation: invitation, hash: hash, carol: carol, identifier: identifier}
    end)
  end

  defp state(%{group: group, invitation: invitation, carol: carol, identifier: identifier}) do
    unboxed(fn ->
      %{
        redeemed_by: Arca.Repo.get!(Invitation, invitation.id).redeemed_by,
        seats:
          Arca.Repo.aggregate(
            from(m in Membership, where: m.user_id == ^carol.id and m.athanor_id == ^group.id),
            :count
          ),
        door: Arca.Repo.all(from(e in Entry, where: e.value == ^identifier, select: e.effect))
      }
    end)
  end

  test "a deny committed between the door's check and the redemption's write wins",
       %{hash: hash, carol: carol, identifier: identifier} = context do
    test = self()

    redeeming =
      Task.async(fn ->
        unboxed(fn ->
          checked = Store.denied(carol.id, identifier)
          send(test, {:checked, checked})

          receive do
            :go -> Invitations.redeem_for(hash, carol.id)
          end
        end)
      end)

    assert_receive {:checked, {:ok, false}}, 5_000
    {:ok, _deny} = unboxed(fn -> Store.deny("identifier", identifier, "ops") end)
    send(redeeming.pid, :go)

    assert {:error, {:door, :denied}} = Task.await(redeeming, 25_000)
    assert state(context) == %{redeemed_by: nil, seats: 0, door: ["deny"]}
  end

  test "a deny of the person committed between the check and the write wins",
       %{hash: hash, carol: carol, identifier: identifier} = context do
    test = self()

    redeeming =
      Task.async(fn ->
        unboxed(fn ->
          checked = Store.denied(carol.id, identifier)
          send(test, {:checked, checked})

          receive do
            :go -> Invitations.redeem_for(hash, carol.id)
          end
        end)
      end)

    assert_receive {:checked, {:ok, false}}, 5_000
    {:ok, _deny} = unboxed(fn -> Store.deny("person", carol.id, "ops") end)
    send(redeeming.pid, :go)

    assert {:error, {:door, :denied}} = Task.await(redeeming, 25_000)
    assert state(context) == %{redeemed_by: nil, seats: 0, door: []}
  end

  @tag :postgres
  test "a deny committed inside the redemption, after its conditional write, wins",
       %{hash: hash, carol: carol, identifier: identifier} = context do
    assert postgres?()
    test = self()
    handler = "invitations-race-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if Process.get(:redeeming) and metadata[:source] == "invitations" and
               String.starts_with?(metadata[:query] || "", "UPDATE") do
            Process.delete(:redeeming)
            send(test, :redeemed_uncommitted)

            receive do
              :go -> :ok
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    redeeming =
      Task.async(fn ->
        unboxed(fn ->
          Process.put(:redeeming, true)
          Invitations.redeem_for(hash, carol.id)
        end)
      end)

    assert_receive :redeemed_uncommitted, 10_000
    {:ok, _deny} = unboxed(fn -> Store.deny("identifier", identifier, "ops") end)
    send(redeeming.pid, :go)

    assert {:error, {:door, :denied}} = Task.await(redeeming, 25_000)
    assert state(context) == %{redeemed_by: nil, seats: 0, door: ["deny"]}
  end

  defp cleanup!(keys, identifier) do
    people =
      Arca.Repo.all(from(i in ExternalIdentity, where: i.key in ^keys, select: i.user_id))

    athanors =
      Arca.Repo.all(
        from(a in Athanor,
          where: a.owner_user_id in ^people or a.created_by in ^people,
          select: a.id
        )
      )

    Arca.Repo.delete_all(from(e in Entry, where: e.value in ^[identifier | people]))
    Arca.Repo.delete_all(from(i in Invitation, where: i.issued_by in ^people))

    Arca.Repo.delete_all(
      from(m in Membership, where: m.user_id in ^people or m.athanor_id in ^athanors)
    )

    Arca.Repo.delete_all(from(p in PersonIdentity, where: p.user_id in ^people))
    Arca.Repo.delete_all(from(i in ExternalIdentity, where: i.user_id in ^people))
    Arca.Repo.delete_all(from(a in Athanor, where: a.id in ^athanors))
    Arca.Repo.delete_all(from(u in User, where: u.id in ^people))
  end
end
