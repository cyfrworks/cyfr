# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.SignInTest do
  use ExUnit.Case, async: false

  alias Sanctum.SignIn
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp info(n, overrides \\ %{}) do
    Map.merge(
      %{
        id: "github|https://github.com|#{n}",
        provider: :github,
        email: "user#{n}@example.com",
        verified: true,
        name: "User #{n}"
      },
      overrides
    )
  end

  test "an admitted person gets a users row, refreshed on every sign-in" do
    i = info(1)
    assert {:ok, user} = SignIn.admitted(i, :allowed)
    assert user.id == i.id
    assert user.email == "user1@example.com"
    assert user.display_name == "User 1"
    assert user.email_verified
    first = user.first_seen_at

    assert {:ok, again} = SignIn.admitted(%{i | name: "Renamed"}, :allowed)
    assert again.first_seen_at == first
    assert again.display_name == "Renamed"
    assert DateTime.compare(again.last_seen_at, first) in [:gt, :eq]
  end

  test "an operator gets the platform row and a seat in Home, minted once and audited once" do
    handler = "signin-test-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:cyfr, :sanctum, :tenancy, :platform_admin_bootstrap],
      fn _e, _m, meta, _c -> send(parent, {:bootstrap, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    i = info(2)
    assert {:ok, _} = SignIn.admitted(i, :admin)
    assert_receive {:bootstrap, %{user_id: uid}}
    assert uid == i.id

    rows = rows!(Members.list_by_user(i.id))
    assert Enum.any?(rows, &(&1.scope == "platform"))
    home = Athanors.home!()
    assert Enum.any?(rows, &(&1.scope == "athanor" and &1.athanor_id == home.id))

    assert {:ok, _} = SignIn.admitted(i, :admin)
    refute_receive {:bootstrap, _}
    # the platform row, the Home seat, and the seat in their own athanor
    assert length(rows!(Members.list_by_user(i.id))) == 3
  end

  test "an email dropped from the operator list loses the platform row on the next sign-in" do
    i = info(3)
    assert {:ok, _} = SignIn.admitted(i, :admin)
    assert Enum.any?(rows!(Members.list_by_user(i.id)), &(&1.scope == "platform"))

    assert {:ok, _} = SignIn.admitted(i, :allowed)
    refute Enum.any?(rows!(Members.list_by_user(i.id)), &(&1.scope == "platform"))
    # the Home seat is an ordinary membership and stays
    assert Enum.any?(rows!(Members.list_by_user(i.id)), &(&1.scope == "athanor"))
  end

  test "invited rows for the person's verified email activate on first sign-in" do
    {:ok, group} = Athanors.create_group("github|https://github.com|creator", "Home Team")
    {:ok, :invited} = Members.add(group, [email: "User4@Example.com"], "creator")

    assert [%{status: "invited", email: "user4@example.com"}] =
             Enum.filter(rows!(Members.list_by_athanor(group.id)), &(&1.status == "invited"))

    i = info(4)
    assert {:ok, _} = SignIn.admitted(i, :allowed)

    assert Members.member?(i.id, group.id)
    refute Enum.any?(rows!(Members.list_by_athanor(group.id)), &(&1.status == "invited"))
  end

  test "only a proved address claims its invitations; the seat waits for the rest" do
    # Admission and seating are different questions. The door may let an
    # identity in on an unasserted address (`*`, or a `user_id` entry), but an
    # invited row is keyed on the email alone, so seating it needs the address
    # proved — otherwise an issuer asserting someone else's address inherits
    # their groups. The seat is held, not withdrawn.
    for {n, claim} <- [{5, :unknown}, {9, false}] do
      {:ok, group} = Athanors.create_group("github|https://github.com|creator2", "Team #{n}")
      {:ok, :invited} = Members.add(group, [email: "user#{n}@example.com"], "creator2")

      assert {:ok, _} = SignIn.admitted(info(n, %{verified: claim}), :allowed)

      refute Members.member?(info(n).id, group.id)
      assert Enum.any?(rows!(Members.list_by_athanor(group.id)), &(&1.status == "invited"))
    end

    {:ok, group} = Athanors.create_group("github|https://github.com|creator2", "Proved Team")
    {:ok, :invited} = Members.add(group, [email: "user11@example.com"], "creator2")

    assert {:ok, %{email_verified: true}} =
             SignIn.admitted(info(11, %{verified: true}), :allowed)

    assert Members.member?(info(11).id, group.id)
    refute Enum.any?(rows!(Members.list_by_athanor(group.id)), &(&1.status == "invited"))
  end

  test "record_namespace/2 lands the claim on the users row and refuses a slug another identity holds" do
    i = info(6)
    assert {:ok, %{personal_athanor_id: pid}} = SignIn.admitted(i, :allowed)

    assert {:ok, user} = SignIn.record_namespace(i.id, "user6ns")
    assert user.namespace == "user6ns"
    assert {:ok, %{id: id}} = Users.get_by_namespace("user6ns")
    assert id == i.id
    # the athanor was theirs since admission; the claim does not re-address it
    assert {:ok, %{personal_athanor_id: ^pid}} = Users.get(i.id)
    assert {:ok, %{kind: "person"}} = Athanors.get(pid)
    assert Sanctum.Namespace.lookup(i.id) == "user6ns"

    # Idempotent; a different slug from the registry keeps the recorded one.
    assert {:ok, %{namespace: "user6ns"}} = SignIn.record_namespace(i.id, "user6ns")
    assert {:ok, %{namespace: "user6ns"}} = SignIn.record_namespace(i.id, "user6other")

    # Another identity cannot take it, and a malformed slug is refused.
    j = info(7)
    assert {:ok, _} = SignIn.admitted(j, :allowed)

    assert {:error, :namespace_owned_by_another_identity} =
             SignIn.record_namespace(j.id, "user6ns")

    assert {:error, :invalid_slug} = SignIn.record_namespace(j.id, "Not A Slug")

    assert {:error, :not_found} =
             SignIn.record_namespace("github|https://github.com|ghost", "ghost")
  end

  test "`*` on the door admits a stranger who then gets their own athanor — no platform bit, no group" do
    n = System.unique_integer([:positive])
    i = info(n, %{email: "stranger#{n}@example.com"})
    {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "ops")

    assert {:ok, verdict} = Sanctum.Door.admit(i.id, i.email, true)
    assert verdict == :allowed

    assert {:ok, %{personal_athanor_id: pid}} = SignIn.admitted(i, verdict)
    assert {:ok, user} = SignIn.record_namespace(i.id, "stranger#{n}")

    assert {:ok, %{kind: "person", owner_user_id: owner}} = Athanors.get(pid)
    assert owner == user.id

    rows = rows!(Members.list_by_user(user.id))
    refute Enum.any?(rows, &(&1.scope == "platform"))
    assert Enum.map(Athanors.list_for_user(user.id), & &1.kind) == ["person"]
  end

  defp rows!({:ok, rows}), do: rows
end
