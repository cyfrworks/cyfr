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
             Enum.filter(Members.list(group.id), &(&1.status == "invited"))

    i = info(4)
    assert {:ok, _} = SignIn.admitted(i, :allowed)

    assert Members.member?(i.id, group.id)
    refute Enum.any?(Members.list(group.id), &(&1.status == "invited"))
  end

  test "an unverified email activates nothing" do
    {:ok, group} = Athanors.create_group("github|https://github.com|creator2", "Other Team")
    {:ok, :invited} = Members.add(group, [email: "user5@example.com"], "creator2")

    assert {:ok, _} = SignIn.admitted(info(5, %{verified: :unknown}), :allowed)
    refute Members.member?(info(5).id, group.id)
    assert Enum.any?(Members.list(group.id), &(&1.status == "invited"))
  end

  test "the namespace is recorded when the person has claimed one" do
    i = info(6)

    :ok =
      Compendium.Registry.CredentialStore.put_push_token(
        i.id,
        Compendium.Registry.canonical_host(),
        "user6ns",
        "cyfr_pt_x",
        "owner"
      )

    assert {:ok, user} = SignIn.admitted(i, :allowed)
    assert user.namespace == "user6ns"
    assert {:ok, %{id: id}} = Users.get_by_namespace("user6ns")
    assert id == i.id
  end
end
