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

  # Missing provider fields must preserve previously recorded display data.
  test "a sign-in that asserts no name or email keeps what is already stored" do
    stored = person(41, %{email: "keep@example.com", name: "Keep Me"})
    assert stored.display_name == "Keep Me"

    {:ok, refreshed} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|41",
        provider: "github",
        email: nil,
        name: nil,
        verified: true
      })

    assert refreshed.id == stored.id
    assert refreshed.display_name == "Keep Me"
    assert refreshed.email == "keep@example.com"
  end

  test "a sign-in that does assert them updates" do
    stored = person(42, %{email: "old@example.com", name: "Old Name"})

    {:ok, refreshed} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|42",
        provider: "github",
        email: "new@example.com",
        name: "New Name",
        verified: true
      })

    assert refreshed.id == stored.id
    assert refreshed.display_name == "New Name"
    assert refreshed.email == "new@example.com"
  end

  test "a person is minted with an id of this server's, named by the identity that signed in" do
    n = System.unique_integer([:positive])
    key = "github|https://github.com|minted-#{n}"
    user = person(n, %{id: key})

    assert Arca.Schemas.User.person_id?(user.id)
    refute user.id == key
    assert {:ok, %{id: same}} = Users.get_by_identity(key)
    assert same == user.id
    assert [%{key: ^key, provider: "github", subject: subject}] = Users.identities(user.id)
    assert subject == "minted-#{n}"

    # The same identity signs in again: the same person, not a second one.
    assert person(n, %{id: key}).id == user.id
    assert {:error, :not_found} = Users.get_by_identity("github|https://github.com|nobody-#{n}")
  end

  test "only an IdP identity signs in: synthetic principal ids and bare ids are refused" do
    for id <- ["system", "_seed", "_health_probe", "webhook:orders", "aqua", "no-pipes", "usr_x"] do
      assert {:error, :not_an_identity} =
               Users.upsert_from_provider(%{id: id, provider: "github", email: "x@example.com"})
    end

    # A row's id is a person's, never a synthetic principal's.
    refute Arca.Schemas.User.person_id?("system")
    refute Arca.Schemas.User.person_id?("webhook:orders")
    assert Arca.Schemas.User.person_id?("usr_01")
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

  test "personal_athanor_id/1 and own_athanor?/2 are the one read of a person's own furnace" do
    u = person(7)

    # Known, but no furnace minted yet — and an unknown id, and no id at all.
    assert :none = Users.personal_athanor_id(u.id)
    assert :none = Users.personal_athanor_id("github|https://github.com|nobody")
    assert :none = Users.personal_athanor_id(nil)
    refute Users.own_athanor?(u.id, "ath_anything")

    {:ok, personal} =
      Athanors.create(%{
        kind: "person",
        name: "P7",
        slug: "p7-#{System.unique_integer([:positive])}",
        owner_user_id: u.id,
        created_by: u.id
      })

    {:ok, _} = Users.set_personal_athanor(u, personal.id)

    assert {:ok, personal.id} == Users.personal_athanor_id(u.id)
    assert Users.own_athanor?(u.id, personal.id)
    refute Users.own_athanor?(u.id, "ath_elsewhere")
    # A context with no person (the public or an internal one) is never at home.
    refute Users.own_athanor?(nil, personal.id)
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
    do:
      athanor_id |> Members.list_by_athanor() |> rows!() |> Enum.filter(&(&1.status == "invited"))

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
    {:ok, out} = Sanctum.Tenancy.revalidate(ctx)
    refute out.authenticated
    assert out.athanor_id == nil
  end

  defp rows!({:ok, rows}), do: rows
end
