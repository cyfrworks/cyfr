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

    rows = Members.list_by_user(i.id)
    assert Enum.any?(rows, &(&1.scope == "platform"))
    home = Athanors.home!()
    assert Enum.any?(rows, &(&1.scope == "athanor" and &1.athanor_id == home.id))

    assert {:ok, _} = SignIn.admitted(i, :admin)
    refute_receive {:bootstrap, _}
    assert length(Members.list_by_user(i.id)) == 2
  end

  test "an email dropped from the operator list loses the platform row on the next sign-in" do
    i = info(3)
    assert {:ok, _} = SignIn.admitted(i, :admin)
    assert Enum.any?(Members.list_by_user(i.id), &(&1.scope == "platform"))

    assert {:ok, _} = SignIn.admitted(i, :allowed)
    refute Enum.any?(Members.list_by_user(i.id), &(&1.scope == "platform"))
    # the Home seat is an ordinary membership and stays
    assert Enum.any?(Members.list_by_user(i.id), &(&1.scope == "athanor"))
  end

  test "invited rows for the person's verified email activate on first sign-in" do
    {:ok, group} = Athanors.create_group("github|https://github.com|creator", "Home Team")
    {:ok, :invited} = Members.add(group, [email: "User4@Example.com"], "creator")

    assert [%{status: "invited", email: "user4@example.com"}] =
             Enum.filter(Members.list_by_athanor(group.id), &(&1.status == "invited"))

    i = info(4)
    assert {:ok, _} = SignIn.admitted(i, :allowed)

    assert Members.member?(i.id, group.id)
    refute Enum.any?(Members.list_by_athanor(group.id), &(&1.status == "invited"))
  end

  test "an address the provider never claimed activates its invitations; one it refuses does not" do
    {:ok, group} = Athanors.create_group("github|https://github.com|creator2", "Other Team")
    {:ok, :invited} = Members.add(group, [email: "user5@example.com"], "creator2")

    # An issuer that emits no `email_verified` (many enterprise IdPs) must not
    # read as one that denied the address: the door already admitted them.
    assert {:ok, %{email_verified: nil}} =
             SignIn.admitted(info(5, %{verified: :unknown}), :allowed)

    assert Members.member?(info(5).id, group.id)

    {:ok, group2} = Athanors.create_group("github|https://github.com|creator2", "Refused Team")
    {:ok, :invited} = Members.add(group2, [email: "user9@example.com"], "creator2")

    assert {:ok, %{email_verified: false}} =
             SignIn.admitted(info(9, %{verified: false}), :allowed)

    refute Members.member?(info(9).id, group2.id)
    assert Enum.any?(Members.list_by_athanor(group2.id), &(&1.status == "invited"))
  end

  test "record_namespace/2 lands the claim on the users row, mints the athanor, and refuses a slug another identity holds" do
    i = info(6)
    assert {:ok, _} = SignIn.admitted(i, :allowed)

    assert {:ok, user} = SignIn.record_namespace(i.id, "user6ns")
    assert user.namespace == "user6ns"
    assert {:ok, %{id: id}} = Users.get_by_namespace("user6ns")
    assert id == i.id
    assert {:ok, %{kind: "person"}} = Athanors.get_by_slug("person", "user6ns")
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

    assert {:ok, _} = SignIn.admitted(i, verdict)
    assert {:ok, user} = SignIn.record_namespace(i.id, "stranger#{n}")

    assert {:ok, %{kind: "person", owner_user_id: owner}} =
             Athanors.get_by_slug("person", "stranger#{n}")

    assert owner == user.id

    rows = Members.list_by_user(user.id)
    refute Enum.any?(rows, &(&1.scope == "platform"))
    assert Enum.map(Athanors.list_for_user(user.id), & &1.kind) == ["person"]
  end
end
