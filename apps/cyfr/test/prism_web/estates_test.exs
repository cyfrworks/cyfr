# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.EstatesTest do
  # One spelling of "what to call this estate to this person": the
  # person's OWN athanor is "You" — theirs, not any person-kind athanor an
  # operator happens to have opened.
  use ExUnit.Case, async: false

  alias PrismWeb.Estates
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "local|idp|alice-#{n}",
        provider: "local",
        name: "Alice",
        email: "alice-#{n}@example.com"
      })

    alice = user.id

    {:ok, mine} =
      Athanors.create(%{
        kind: "person",
        name: "Alice",
        slug: "alice-#{n}",
        owner_user_id: alice,
        created_by: alice
      })

    {:ok, _} = Users.set_personal_athanor(user, mine.id)
    {:ok, _} = Members.create(%{user_id: alice, scope: "athanor", athanor_id: mine.id})
    {:ok, alice: alice, mine: mine, n: n}
  end

  test "the person's own athanor is You, another person's is theirs", %{
    alice: alice,
    mine: mine,
    n: n
  } do
    me = %{user_id: alice}
    assert Estates.label(mine, me) == "You"
    assert Estates.own?(mine, me)

    operator = %{user_id: "local|idp|operator-#{n}"}
    assert Estates.label(mine, operator) == "Alice"
    refute Estates.own?(mine, operator)

    assert Estates.label(mine, nil) == "Alice"
  end

  test "a group is its name and a pair is the other person", %{alice: alice, n: n} do
    {:ok, group} = Athanors.create_group(alice, "Trip #{n}")
    assert Estates.label(group, %{user_id: alice}) == "Trip #{n}"

    {:ok, %{id: bob}} =
      Users.upsert_from_provider(%{
        id: "local|idp|bob-#{n}",
        provider: "local",
        name: "Bob",
        email: "bob-#{n}@example.com"
      })

    {:ok, _} = Members.add(group, [user_id: bob], alice)
    {:ok, pair} = Athanors.create_pair(alice, bob)
    assert Estates.label(pair, %{user_id: alice}) == "Bob"
    assert Estates.label(pair, %{user_id: bob}) == "Alice"
  end
end
