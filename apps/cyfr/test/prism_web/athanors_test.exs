# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AthanorsTest do
  # One spelling of "what to call this athanor to this person": the
  # person's OWN athanor is "You" — the one their row names as theirs —
  # and another person's is its name.
  use ExUnit.Case, async: false

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "local|idp|alice-#{n}",
        provider: "local",
        name: "Alice",
        email: "alice-#{n}@example.com"
      })

    alice = user.id

    mine = Sanctum.Test.People.athanor!(user)
    {:ok, alice: alice, mine: mine, n: n}
  end

  test "the person's own athanor is You, another person's is theirs", %{
    alice: alice,
    mine: mine,
    n: n
  } do
    me = %{user_id: alice}
    assert PrismWeb.Athanors.label(mine, me) == "You"
    assert PrismWeb.Athanors.own?(mine, me)

    operator = %{user_id: "local|idp|operator-#{n}"}
    assert PrismWeb.Athanors.label(mine, operator) == "Alice"
    refute PrismWeb.Athanors.own?(mine, operator)

    assert PrismWeb.Athanors.label(mine, nil) == "Alice"
  end
end
