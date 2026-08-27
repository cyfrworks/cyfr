# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.UsersTest do
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp person(n, overrides \\ %{}) do
    {:ok, user} =
      Users.upsert_from_provider(
        Map.merge(
          %{
            id: "github|https://github.com|#{n}",
            provider: "github",
            email: "P#{n}@Example.com",
            verified: true,
            name: "Person #{n}"
          },
          overrides
        )
      )

    user
  end

  test "email is stored lowercased and is not unique — two identities may share one" do
    a = person(1, %{email: "Same@Example.com"})
    b = person(2, %{id: "google|https://accounts.google.com|2", email: "same@example.com"})
    assert a.email == "same@example.com"
    assert b.email == "same@example.com"
    assert length(Users.list_by_email("SAME@example.com")) == 2
  end

  test "a users row is a person: synthetic principal ids are refused" do
    for id <- ["system", "_seed", "_health_probe", "webhook:orders", "aqua", "no-pipes"] do
      assert {:error, %Ecto.Changeset{errors: errors}} =
               Users.upsert_from_provider(%{id: id, provider: "github", email: "x@example.com"})

      assert Keyword.has_key?(errors, :id), "#{id} was accepted as a person"
    end
  end

  test "list/1 pages the people the server knows" do
    a = person(7)
    b = person(8)
    all = Users.list() |> Enum.map(& &1.id)
    assert a.id in all and b.id in all
    assert length(Users.list(limit: 1)) == 1
    assert Users.list(limit: 1) != Users.list(limit: 1, offset: 1)
  end

  test "prefs are a merged JSON document" do
    u = person(3)
    assert Users.prefs(u) == %{}
    {:ok, u} = Users.put_prefs(u, %{"mode" => "lite"})
    {:ok, u} = Users.put_prefs(u, %{"theme" => "dark"})
    assert Users.prefs(u) == %{"mode" => "lite", "theme" => "dark"}
  end

  test "deny ejects: sessions and keys revoked, own athanor archived, group rows gone" do
    u = person(4)

    {:ok, personal} =
      Athanors.create(%{
        kind: "person",
        name: "P4",
        slug: "p4-#{System.unique_integer([:positive])}",
        owner_user_id: u.id,
        created_by: u.id
      })

    {:ok, u} = Users.set_personal_athanor(u, personal.id)
    {:ok, group} = Athanors.create_group("github|https://github.com|owner4", "G4")
    {:ok, :added} = Members.add(group, [user_id: u.id], "owner4")

    ctx =
      Context.build(
        user_id: u.id,
        athanor_id: personal.id,
        provider: "github",
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.Session.create(ctx)
    {:ok, %{api_key: key}} = Sanctum.ApiKey.create(ctx, %{name: "k4"})

    Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Session.topic())

    assert {:ok, denied} = Users.deny(u)
    assert denied.status == "denied"
    assert denied.denied_at

    assert {:error, _} = Sanctum.Session.load(session.token, surface: :console)
    assert_receive {:sessions_revoked, uid}
    assert uid == u.id
    assert {:error, :revoked} = Sanctum.ApiKey.validate(key, [])
    assert {:ok, %{status: "archived"}} = Athanors.get(personal.id)
    refute Members.member?(u.id, group.id)

    # allow reverses the standing, reopens the athanor and seats its owner in
    # it again; the credentials stay revoked and the group seat stays gone
    assert {:ok, %{status: "active"}} = Users.allow(denied)
    assert {:ok, %{status: "active"}} = Athanors.get(personal.id)
    assert Members.member?(u.id, personal.id)
    refute Members.member?(u.id, group.id)
    assert {:error, :revoked} = Sanctum.ApiKey.validate(key, [])
  end

  test "deny withdraws the group seats the address was still holding" do
    u = person(41)
    {:ok, group} = Athanors.create_group("github|https://github.com|owner41", "G41")

    # An invitation names an email and no person: the deny's sweep by user id
    # cannot see it, so it has to be withdrawn by address.
    {:ok, :invited} = Members.add(group, [email: "invitee41@example.com"], "owner41")
    assert [_] = invited_rows(group.id)

    assert 1 == Members.withdraw_invites_for_email("INVITEE41@example.com")
    assert invited_rows(group.id) == []

    # and a seat left over for a person's own address goes with their deny
    {:ok, group2} = Athanors.create_group("github|https://github.com|owner41", "G41b")

    {:ok, _} =
      Members.create(%{
        email: String.downcase(u.email),
        scope: "athanor",
        status: "invited",
        athanor_id: group2.id,
        added_by: "owner41"
      })

    assert {:ok, _} = Users.deny(u)
    assert invited_rows(group2.id) == []
  end

  defp invited_rows(athanor_id),
    do: athanor_id |> Members.list_by_athanor() |> rows!() |> Enum.filter(&(&1.status == "invited"))

  test "revalidate drops a denied person's session context to unauthenticated" do
    u = person(5)

    ctx =
      Context.build(
        user_id: u.id,
        athanor_id: Sanctum.TestContext.athanor_id(),
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, _} = Users.deny(u)
    out = Sanctum.Tenancy.revalidate(ctx)
    refute out.authenticated
    assert out.athanor_id == nil
  end
  defp rows!({:ok, rows}), do: rows
end
