# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.UsersTest do
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Users}

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

  # A person with no athanor of their own yet: the row alone.
  defp unhoused do
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

  test "a person is found by an account's identifier alone: synthetic principal ids and bare ids name no one" do
    for id <- ["system", "_seed", "_health_probe", "webhook:orders", "aqua", "no-pipes", "usr_x"] do
      assert {:error, :not_found} = Users.get_by_identifier(id)
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

  test "own_athanor?/2 reads the owner" do
    u = unhoused()

    # Known, but no furnace minted yet.
    refute Users.own_athanor?(u.id, "ath_anything")

    {:ok, personal} =
      Athanors.create(%{
        name: "P7",
        slug: "p7-#{System.unique_integer([:positive])}",
        owner_user_id: u.id,
        created_by: u.id
      })

    assert Users.own_athanor?(u.id, personal.id)
    refute Users.own_athanor?(u.id, "ath_elsewhere")
    # A context with no person (the public or an internal one) is never at home.
    refute Users.own_athanor?(nil, personal.id)
  end

  test "an athanor whose owner is the person is theirs to every reader" do
    u = unhoused()

    {:ok, own} =
      Athanors.create(%{
        name: "P8",
        slug: "p8-#{System.unique_integer([:positive])}",
        owner_user_id: u.id,
        created_by: u.id
      })

    ctx =
      Context.build(
        user_id: u.id,
        auth_method: :oidc,
        authenticated: true,
        scope: :athanor,
        permissions: Context.person_permissions()
      )

    assert {:ok, %Context{athanor_id: own_id}} = Context.focus(ctx, own.id)
    assert own_id == own.id
    assert Users.own_athanor?(u.id, own.id)

    assert {:ok, %Context{athanor_id: ^own_id}} =
             Sanctum.Tenancy.continuation(u.id, own.id, "interactive")

    # The denial archives the athanor by its owner, and the allow reopens it.
    assert {:ok, _} = Users.deny(u)
    assert {:ok, %{status: "archived"}} = Athanors.get(own.id)
    assert {:ok, _} = Users.allow(%{u | status: "denied"})
    assert {:ok, %{status: "active"}} = Athanors.get(own.id)
  end

  test "deny ejects: sessions and keys revoked, own athanor archived" do
    u = person(4)
    personal = Sanctum.Test.People.athanor!(u)

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

    # allow reverses the standing and reopens the athanor, which its person
    # focuses again; the credentials stay revoked
    assert {:ok, %{status: "active"}} = Users.allow(denied)
    assert {:ok, %{status: "active"}} = Athanors.get(personal.id)
    assert {:ok, %{athanor_id: focused}} = Context.focus(%{ctx | athanor_id: nil}, personal.id)
    assert focused == personal.id
    assert {:error, :revoked} = Sanctum.ApiKey.validate(key, [])
  end

  # A denial revokes every share of the person's own athanor in its
  # transaction, and each is announced once it committed, so recipients in
  # other athanors read what they are offered again. No person acts.
  test "deny announces every share it revoked, once" do
    terry = Arca.Test.Shares.owner!()
    share = Arca.Test.Shares.share!(terry.actor, Arca.Test.Shares.entry!(terry.actor).id)
    {:ok, u} = Users.get(terry.user.id)

    Sanctum.Test.ShareAnnouncements.listen()
    assert {:ok, %{status: "denied"}} = Users.deny(u)

    share_id = share.id

    assert_receive {:share_announced, :revoked,
                    %{share_id: ^share_id, kind: :revoked, user_id: nil}}

    refute_receive {:share_announced, _kind, %{share_id: ^share_id}}, 100

    # A denial again finds no active share, and announces none.
    assert {:ok, _} = Users.deny(u)
    refute_receive {:share_announced, _kind, %{share_id: ^share_id}}, 100
  end

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
end
