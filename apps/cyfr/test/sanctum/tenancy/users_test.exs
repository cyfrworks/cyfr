# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.UsersTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    :ok
  end

  defp info(n, overrides) do
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
  end

  defp person(n, overrides \\ %{}) do
    {:ok, user} = Sanctum.Test.People.linked(info(n, overrides))
    user
  end

  # A person with no athanor of their own yet: the row and its linked
  # sign-in method alone.
  defp unhoused(n) do
    now = DateTime.utc_now()

    {:ok, %{id: user_id}} =
      Arca.Test.People.mint(
        Prima.Actor.system(),
        %{
          id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        },
        %{
          key: "github|https://github.com|unhoused-#{n}",
          provider: "github",
          issuer: "https://github.com",
          subject: "unhoused-#{n}",
          first_seen_at: now,
          last_seen_at: now
        }
      )

    {:ok, user} = Users.get(user_id)
    user
  end

  test "email is stored lowercased and is not unique — two people may share one" do
    a = person(1, %{email: "Same@Example.com"})
    b = person(2, %{id: "google|https://accounts.google.com|2", email: "same@example.com"})
    assert a.email == "same@example.com"
    assert b.email == "same@example.com"
    refute a.id == b.id
  end

  # Missing provider fields must preserve previously recorded display data.
  test "a sign-in that asserts no name or email keeps what is already stored" do
    stored = person(41, %{email: "keep@example.com", name: "Keep Me"})
    assert stored.display_name == "Keep Me"

    {:ok, refreshed} = Users.seen(stored, info(41, %{email: nil, name: nil}))

    assert refreshed.id == stored.id
    assert refreshed.display_name == "Keep Me"
    assert refreshed.email == "keep@example.com"
  end

  test "a sign-in that does assert them updates, and an email only when the provider proved it" do
    stored = person(42, %{email: "old@example.com", name: "Old Name", verified: false})
    refute stored.email_verified

    {:ok, refreshed} =
      Users.seen(stored, info(42, %{email: "new@example.com", name: "New Name"}))

    assert refreshed.id == stored.id
    assert refreshed.display_name == "New Name"
    assert refreshed.email == "new@example.com"
    assert refreshed.email_verified

    for verified <- [false, :unknown] do
      {:ok, unproved} =
        Users.seen(refreshed, info(42, %{email: "unproved@example.com", verified: verified}))

      assert unproved.email == "new@example.com"
      assert unproved.email_verified
    end
  end

  test "a person's id is this server's, and the method they linked unlocks them and no one else" do
    n = System.unique_integer([:positive])
    key = "github|https://github.com|minted-#{n}"
    user = person(n, %{id: key})

    assert Prima.PersonId.person?(user.id)
    refute user.id == key
    assert {:ok, %{id: same}} = Users.get_by_identity(key)
    assert same == user.id
    assert [%{key: ^key, provider: "github", subject: subject}] = Users.identities(user.id)
    assert subject == "minted-#{n}"

    # The same method signs in again: the same person, not a second one.
    people = Arca.Repo.aggregate(Arca.Schemas.User, :count)
    assert {:ok, %{id: ^same}} = Sanctum.SignIn.unlock(info(n, %{id: key}))

    # A method no person here linked unlocks no one, and makes no one.
    nobody = "github|https://github.com|nobody-#{n}"
    assert {:error, :no_person} = Sanctum.SignIn.unlock(info(n, %{id: nobody}))
    assert {:error, :not_found} = Users.get_by_identity(nobody)
    assert Arca.Repo.aggregate(Arca.Schemas.User, :count) == people
  end

  test "only an IdP identity is a sign-in method: synthetic principal ids and bare ids name no one" do
    for id <- ["system", "_seed", "_health_probe", "webhook:orders", "aqua", "no-pipes", "usr_x"] do
      refute Sanctum.Auth.Identity.key?(id)

      assert {:error, :no_person} =
               Sanctum.SignIn.unlock(%{id: id, provider: "github", email: "x@example.com"})
    end

    # A row's id is a person's, never a synthetic principal's.
    refute Prima.PersonId.person?("system")
    refute Prima.PersonId.person?("webhook:orders")
    assert Prima.PersonId.person?("usr_01")
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
    u = unhoused(7)

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
    personal = Sanctum.Test.People.athanor!(u)
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

    {:ok, session} = Sanctum.TestContext.create_session(ctx)
    {:ok, %{api_key: key}} = Sanctum.TestContext.create_key(ctx, %{name: "k4"})

    Cyfr.Bus.subscribe_global(Cyfr.Bus.sessions())

    assert {:ok, denied} = Users.deny(u)
    assert denied.status == "denied"
    assert denied.denied_at

    assert {:error, _} = Sanctum.Session.load(session.token)
    assert_receive %Cyfr.Bus.Session{kind: :revoked, user_id: uid}
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

  test "a post-restore period is the person's: a denial and an athanor's purge leave it, the users row takes it" do
    u = person(42)
    {:ok, group} = Athanors.create_group("github|https://github.com|owner42", "G42")
    {:ok, :added} = Members.add(group, [user_id: u.id], "owner42")

    # Written straight to the table: its store comes with the declared
    # restore.
    {1, _} =
      Arca.Repo.insert_all("restore_people", [
        %{restore_id: "rst_#{System.unique_integer([:positive])}", user_id: u.id}
      ])

    assert restore_periods(u.id) == 1

    assert {:ok, _} = Users.deny(u)
    assert restore_periods(u.id) == 1

    {:ok, archived} = Athanors.archive(group)
    assert {:ok, counts} = Athanors.destroy(archived)
    refute Map.has_key?(counts, "restore_people")
    assert restore_periods(u.id) == 1

    # Its owner is the person's row: deleting it takes the period.
    assert {1, _} = Arca.Repo.delete_all(from(p in "users", where: p.id == ^u.id))
    assert restore_periods(u.id) == 0
  end

  defp restore_periods(user_id),
    do: Arca.Repo.aggregate(from(r in "restore_people", where: r.user_id == ^user_id), :count)

  test "deny withdraws the group seats the identifier was still holding" do
    n = System.unique_integer([:positive])
    {:ok, group} = Athanors.create_group("github|https://github.com|owner41", "G41")

    # An invitation names an identifier no person here holds: the deny's
    # sweep by user id cannot see it, so it is withdrawn by identifier.
    stranger = "per_" <> Prima.Digest.sha256_hex("invitee-#{n}")
    {:ok, :invited} = Members.add(group, [identifier: stranger], "owner41")
    assert [_] = invited_rows(group.id)

    assert 1 == Members.withdraw_invites_for_identifier(stranger)
    assert invited_rows(group.id) == []

    # and a seat left waiting on a person's own identifier goes with their
    # deny
    identifier = "per_" <> Prima.Digest.sha256_hex("held-#{n}")

    {:ok, u} =
      Sanctum.Test.People.remote(
        %{
          id: Sanctum.Auth.Identity.cyfr_key("https://dir.example", identifier),
          provider: "cyfr"
        },
        %{identifier: identifier, directory_url: "https://dir.example"}
      )

    {:ok, group2} = Athanors.create_group("github|https://github.com|owner41", "G41b")

    {:ok, _} =
      Members.create(%{
        person_identifier: identifier,
        scope: "athanor",
        status: "invited",
        athanor_id: group2.id,
        added_by: "owner41"
      })

    assert [_] = invited_rows(group2.id)
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
