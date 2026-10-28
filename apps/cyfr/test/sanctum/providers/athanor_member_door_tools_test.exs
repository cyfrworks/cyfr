# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.AthanorMemberDoorToolsTest do
  @moduledoc """
  The tenancy verbs through the MCP registry: `athanor.*`, `member.*` and
  `door.*` — who may call them, what they answer, and what they never leak.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Refusals
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Members, Users}
  alias Sanctum.Test.DirectoryServer

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    n = System.unique_integer([:positive])

    # Local people, each named by their own id; `ops` holds the platform
    # grant.
    [alice, bob, ops] =
      for name <- ["alice", "bob", "ops"] do
        {:ok, user} =
          Sanctum.Test.People.linked(%{
            id: "github|https://github.com|#{name}-#{n}",
            provider: "github",
            email: "#{name}#{n}@example.com",
            verified: true
          })

        user.id
      end

    {:ok, _} = Sanctum.TestContext.ensure_platform(ops)

    ctx = fn user_id, athanor_id, opts ->
      Context.build(
        user_id: user_id,
        athanor_id: athanor_id,
        provider: "github",
        permissions: [:*],
        scope: :athanor,
        auth_method: Keyword.get(opts, :auth_method, :oidc),
        authenticated: true,
        platform_admin: Keyword.get(opts, :platform_admin, false)
      )
    end

    {:ok, alice: alice, bob: bob, ops: ops, ctx: ctx, n: n}
  end

  defp call(ctx, tool, args), do: Sanctum.Gate.call_external(tool, ctx, args)

  test "a person creates a group, is its only member, and the others see it once added",
       %{alice: alice, bob: bob, ctx: ctx, n: n} do
    a = ctx.(alice, Sanctum.TestContext.athanor_id(), [])

    assert {:ok, group} = call(a, "athanor", %{"action" => "create", "name" => "Family #{n}"})
    assert group.kind == "group"
    assert group.member_count == 1
    assert String.starts_with?(group.slug, "family-")

    {:ok, %{athanors: mine}} = call(a, "athanor", %{"action" => "list"})
    assert Enum.any?(mine, &(&1.id == group.id))

    b = ctx.(bob, Sanctum.TestContext.athanor_id(), [])
    {:ok, %{athanors: bobs}} = call(b, "athanor", %{"action" => "list"})
    refute Enum.any?(bobs, &(&1.id == group.id))

    # a non-member cannot act on it, and is told what a missing athanor tells them
    assert {:error, msg} =
             call(b, "member", %{"action" => "list", "athanor" => group.id})

    assert Refusals.render(msg) =~ "not found"

    # add by user id, then bob sees it
    assert {:ok, %{state: "added"}} =
             call(a, "member", %{"action" => "add", "athanor" => group.id, "user_id" => bob})

    {:ok, %{athanors: bobs}} = call(b, "athanor", %{"action" => "list"})
    assert Enum.any?(bobs, &(&1.id == group.id))

    {:ok, %{members: members}} = call(b, "member", %{"action" => "list", "athanor" => group.id})
    assert length(members) == 2

    # bob leaves; alice remains; alice leaves → the group is archived
    assert {:ok, %{state: "left"}} =
             call(b, "member", %{"action" => "leave", "athanor" => group.id})

    assert {:ok, %{state: "left"}} =
             call(a, "member", %{"action" => "leave", "athanor" => group.id})

    assert {:ok, %{status: "archived"}} = Athanors.get(group.id)
  end

  test "an API key cannot create groups or add members, and lists its own athanor alone",
       %{alice: alice, ctx: ctx, n: n} do
    {:ok, home} = Athanors.create_group(alice, "Key home #{n}")
    {:ok, other} = Athanors.create_group(alice, "Elsewhere #{n}")
    k = ctx.(alice, home.id, auth_method: :api_key)

    assert {:error, msg} = call(k, "athanor", %{"action" => "create", "name" => "Nope"})
    assert Refusals.render(msg) =~ "person's act"
    assert {:error, msg} = call(k, "member", %{"action" => "add", "user_id" => alice})
    assert Refusals.render(msg) =~ "person's act"
    # Reads are the key's athanor's, never its creator's other seats.
    assert {:ok, %{athanors: [%{id: id}], count: 1}} = call(k, "athanor", %{"action" => "list"})
    assert id == home.id
    refute id == other.id
  end

  test "a person's own athanor cannot be archived here",
       %{alice: alice, ctx: ctx, n: n} do
    {:ok, athanor} = Athanors.create_group(alice, "Door #{n}")
    {:ok, _} = Members.ensure(alice, scope: "athanor", athanor_id: athanor.id)
    a = ctx.(alice, athanor.id, [])
    personal = personal!(alice)
    assert {:error, msg} = call(a, "athanor", %{"action" => "archive", "athanor" => personal.id})
    assert Refusals.render(msg) =~ "own athanor"
    assert {:error, msg} = call(a, "member", %{"action" => "leave", "athanor" => personal.id})
    assert Refusals.render(msg) =~ "own athanor"
  end

  test "door.* is the operator's: refused for a member, open to an admin; a local person is admitted unless denied",
       %{alice: alice, ops: ops, ctx: ctx, n: n} do
    member = ctx.(alice, Sanctum.TestContext.athanor_id(), [])

    assert {:error, %Prima.Refusal{stage: :admission, reason: :platform_admin_required}} =
             call(member, "door", %{"action" => "list"})

    admin = ctx.(ops, Sanctum.TestContext.athanor_id(), platform_admin: true)
    assert {:ok, %{entries: []}} = call(admin, "door", %{"action" => "list"})

    # A local person needs no entry: their admission was the admitting act.
    {:ok, carol} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|carol-#{n}",
        provider: "github",
        email: "carol#{n}@example.com",
        verified: true
      })

    assert {:ok, :allowed} = Sanctum.Door.admit_person(carol)

    # Allows name an identifier or `*`, never a person or an address.
    identifier = "per_" <> Prima.Digest.sha256_hex("door-op-#{n}")

    assert {:ok, %{kind: "identifier", effect: "allow", note: "friend"}} =
             call(admin, "door", %{"action" => "allow", "value" => identifier, "note" => "friend"})

    assert {:ok, :allowed} = Sanctum.Door.admit_identifier(identifier)

    assert {:ok, %{kind: "wildcard"}} =
             call(admin, "door", %{"action" => "allow", "value" => "*"})

    for value <- [carol.id, "carol#{n}@example.com", "github|https://github.com|carol-#{n}"] do
      assert {:error, {:invalid_argument, _}} =
               call(admin, "door", %{"action" => "allow", "value" => value}),
             "door.allow took #{value}"
    end

    # A deny names a person and ejects them, sticky against `*`.
    assert {:ok, %{kind: "person", effect: "deny", ejected: 1, id: deny_id}} =
             call(admin, "door", %{"action" => "deny", "value" => carol.id})

    assert {:error, :denied} = Sanctum.Door.admit_person(carol)
    assert {:ok, %{status: "denied"}} = Users.get(carol.id)

    # `*` is not denied, and an address is not a person.
    for value <- ["*", "carol#{n}@example.com"] do
      assert {:error, {:invalid_argument, _}} =
               call(admin, "door", %{"action" => "deny", "value" => value}),
             "door.deny took #{value}"
    end

    # The platform administrator is never denied.
    assert {:error, msg} = call(admin, "door", %{"action" => "deny", "value" => ops})
    assert Refusals.render(msg) =~ "platform administrator"
    assert {:ok, :allowed} = Sanctum.Door.admit_person(%{id: ops})

    # Removing the deny lets the person back: nobody is left denied with no
    # entry to say why.
    assert {:ok, %{removed: true, restored: 1}} =
             call(admin, "door", %{"action" => "remove", "id" => deny_id})

    assert {:ok, %{status: "active"}} = Users.get(carol.id)
    assert {:ok, :allowed} = Sanctum.Door.admit_person(carol)
  end

  # A session the door's verdict issued to `user_id`.
  defp session_for(user_id, email) do
    ctx =
      Context.build(
        user_id: user_id,
        email: email,
        provider: "github",
        authenticated: true,
        permissions: [:read]
      )

    {:ok, session} =
      Sanctum.Session.create(ctx, generation_snapshot: Sanctum.TestContext.snapshot!(ctx))

    session
  end

  test "door.remove of an allow through the gate ejects the remote person it admitted, and only them",
       %{alice: alice, ops: ops, ctx: ctx, n: n} do
    admin = ctx.(ops, Sanctum.TestContext.athanor_id(), platform_admin: true)

    # Two remote people, their heads fresh at this home as the CYFR
    # sign-in leaves them, so the door issued each a session.
    tls = DirectoryServer.tls()
    DirectoryServer.listen!()
    DirectoryServer.seam!(tls)
    directory = DirectoryServer.start!(tls)

    [{dave, dave_identifier}, {erin, erin_identifier}] =
      for _name <- ["dave", "erin"] do
        identity = DirectoryServer.identity!(directory.dir, directory.url)

        {:ok, user} =
          Sanctum.Test.People.remote(
            %{
              id: Sanctum.Auth.Identity.cyfr_key(identity.url, identity.identifier),
              provider: "cyfr"
            },
            %{identifier: identity.identifier, directory_url: identity.url}
          )

        _head = DirectoryServer.cached!(identity)
        {user, identity.identifier}
      end

    assert {:ok, %{effect: "allow", id: dave_allow}} =
             call(admin, "door", %{"action" => "allow", "value" => dave_identifier})

    assert {:ok, %{effect: "allow"}} =
             call(admin, "door", %{"action" => "allow", "value" => erin_identifier})

    # What the door issued: a session for each; and a local person's
    # session, which no allow issued.
    dave_session = session_for(dave.id, nil)
    erin_session = session_for(erin.id, nil)
    alice_session = session_for(alice, "alice#{n}@example.com")

    assert {:ok, _} = Sanctum.Session.get(dave_session.token)

    assert {:ok, %{id: ^dave_allow, removed: true, ejected: 1}} =
             call(admin, "door", %{"action" => "remove", "id" => dave_allow})

    assert {:error, :not_allowed} = Sanctum.Door.admit_person(dave)
    assert {:error, :invalid_session} = Sanctum.Session.get(dave_session.token)

    # The person another entry still admits keeps what they hold, and a
    # local person needs no entry at all.
    assert {:ok, :allowed} = Sanctum.Door.admit_person(erin)
    assert {:ok, _} = Sanctum.Session.get(erin_session.token)
    assert {:ok, :allowed} = Sanctum.Door.admit_person(%{id: alice})
    assert {:ok, _} = Sanctum.Session.get(alice_session.token)

    # Closing a door is not denying a person.
    assert {:ok, %{status: "active"}} = Users.get(dave.id)
  end

  test "door.* allows, denies, lists and resolves a person identifier, which the cyfr door is judged by",
       %{ops: ops, ctx: ctx, n: n} do
    admin = ctx.(ops, Sanctum.TestContext.athanor_id(), platform_admin: true)
    identifier = "per_" <> Prima.Digest.sha256_hex("door-tools-#{n}")

    # An unadmitted remote newcomer waits for the operator as an identifier.
    assert {:error, {:door, :not_allowed}} = Sanctum.Door.sign_in_identifier(identifier)

    assert {:ok, %{requests: requests}} = call(admin, "door", %{"action" => "requests"})

    assert [%{id: request_id, kind: "identifier"}] =
             Enum.filter(requests, &(&1.value == identifier))

    assert {:ok, %{kind: "identifier", status: "allowed"}} =
             call(admin, "door", %{
               "action" => "resolve",
               "id" => request_id,
               "decision" => "allow"
             })

    assert {:ok, :allowed} = Sanctum.Door.admit_identifier(identifier)

    # Its shape names its kind; a value of no kind is refused.
    other = "per_" <> Prima.Digest.sha256_hex("door-tools-other-#{n}")

    assert {:ok, %{kind: "identifier", effect: "allow"}} =
             call(admin, "door", %{"action" => "allow", "value" => other})

    assert {:error, {:invalid_argument, message}} =
             call(admin, "door", %{"action" => "allow", "value" => "per_x"})

    assert message =~ "person identifier"

    # A deny by identifier ejects the remote person the door admitted under
    # it, and is sticky against `*`.
    user = remote!(identifier)
    assert {:ok, _} = call(admin, "door", %{"action" => "allow", "value" => "*"})
    assert {:ok, :allowed} = Sanctum.Door.admit_person(user)

    assert {:ok, %{effect: "deny", kind: "identifier", ejected: 1}} =
             call(admin, "door", %{"action" => "deny", "value" => identifier})

    assert {:error, :denied} = Sanctum.Door.admit_person(user)
    assert {:error, :denied} = Sanctum.Door.admit_identifier(identifier)
    assert {:ok, %{status: "denied"}} = Users.get(user.id)

    assert {:ok, %{entries: entries}} = call(admin, "door", %{"action" => "list"})
    assert Enum.any?(entries, &(&1.kind == "identifier" and &1.value == identifier))

    # Allowing the identifier again restores the person.
    assert {:ok, %{effect: "allow", restored: 1}} =
             call(admin, "door", %{"action" => "allow", "value" => identifier})

    assert {:ok, %{status: "active"}} = Users.get(user.id)
    assert {:ok, :allowed} = Sanctum.Door.admit_person(user)
  end

  test "member.add and member.remove take an identifier: an invite waits at the door, list shows it, remove withdraws it",
       %{alice: alice, ctx: ctx, n: n} do
    a = ctx.(alice, Sanctum.TestContext.athanor_id(), [])
    {:ok, group} = call(a, "athanor", %{"action" => "create", "name" => "Ids #{n}"})
    identifier = "per_" <> Prima.Digest.sha256_hex("member-id-#{n}")

    # Nobody here holds it: the seat waits for their first cyfr sign-in,
    # the door queues the identifier for the operator, and the answer is
    # the one a known person's identifier gets.
    assert {:ok, %{state: "added", member: %{identifier: ^identifier}}} =
             call(a, "member", %{
               "action" => "add",
               "athanor" => group.id,
               "identifier" => identifier
             })

    assert {:ok, %{members: members}} =
             call(a, "member", %{"action" => "list", "athanor" => group.id})

    assert [%{status: "invited", user_id: nil, email: nil}] =
             Enum.filter(members, &(&1.identifier == identifier))

    assert [%{kind: "identifier", status: "requested"}] =
             Enum.filter(Sanctum.Door.Store.requests(), &(&1.value == identifier))

    assert {:error, {:invalid_argument, message}} =
             call(a, "member", %{
               "action" => "add",
               "athanor" => group.id,
               "identifier" => "per_x"
             })

    assert message =~ "person identifier"

    # Removing by identifier withdraws the invitation; once gone, there is
    # nobody to remove.
    assert {:ok, %{state: "removed", member: %{identifier: ^identifier}}} =
             call(a, "member", %{
               "action" => "remove",
               "athanor" => group.id,
               "identifier" => identifier
             })

    refute Enum.any?(
             rows!(Members.list_by_athanor(group.id)),
             &(&1.person_identifier == identifier)
           )

    assert {:error, {:not_found, "Member", ^identifier}} =
             call(a, "member", %{
               "action" => "remove",
               "athanor" => group.id,
               "identifier" => identifier
             })
  end

  test "member.remove with invitation withdraws only a pending invitation: a claimed one is not found and its member stays",
       %{alice: alice, ctx: ctx, n: n} do
    a = ctx.(alice, Sanctum.TestContext.athanor_id(), [])
    {:ok, group} = call(a, "athanor", %{"action" => "create", "name" => "Withdraw #{n}"})
    identifier = "per_" <> Prima.Digest.sha256_hex("member-withdraw-#{n}")
    invitee = %{"identifier" => identifier}

    withdraw =
      &Map.merge(%{"action" => "remove", "athanor" => group.id, "invitation" => true}, &1)

    # Pending: it is withdrawn, and a second withdrawal finds nothing.
    {:ok, _} = call(a, "member", Map.merge(%{"action" => "add", "athanor" => group.id}, invitee))
    assert {:ok, %{state: "removed"}} = call(a, "member", withdraw.(invitee))
    assert {:error, {:not_found, "Invitation", _}} = call(a, "member", withdraw.(invitee))

    refute Enum.any?(rows!(Members.list_by_athanor(group.id)), &(&1.status == "invited"))

    # Claimed by the invitee's arrival: the invitation is a seat now, and
    # a withdrawal reaches no seat.
    {:ok, _} = call(a, "member", Map.merge(%{"action" => "add", "athanor" => group.id}, invitee))
    by_identifier = remote!(identifier)
    {:ok, 1} = Members.activate_invited(by_identifier)
    assert Members.member?(by_identifier.id, group.id)

    assert {:error, {:not_found, "Invitation", ^identifier}} =
             call(a, "member", withdraw.(invitee))

    assert Members.member?(by_identifier.id, group.id)

    # A user id holds no invitation; the flag beside one is refused before
    # anything is read.
    assert {:error, {:invalid_argument, "invitation names an identifier"}} =
             call(a, "member", withdraw.(%{"user_id" => by_identifier.id}))

    assert Members.member?(by_identifier.id, group.id)

    # The flag is a boolean, as declared: the gate refuses anything else.
    assert {:error,
            %Prima.Refusal{
              stage: :admission,
              reason: {:invalid_argument, "Field 'invitation' must be a boolean"}
            }} =
             call(a, "member", withdraw.(%{"identifier" => identifier, "invitation" => "yes"}))

    # Without the flag, the identifier names its holder, who is removed.
    assert {:ok, %{state: "removed"}} =
             call(a, "member", %{
               "action" => "remove",
               "athanor" => group.id,
               "identifier" => identifier
             })

    refute Members.member?(by_identifier.id, group.id)
  end

  test "a person here is added and removed by their identifier, and keeps their identity",
       %{alice: alice, ctx: ctx, n: n} do
    a = ctx.(alice, Sanctum.TestContext.athanor_id(), [])
    {:ok, group} = call(a, "athanor", %{"action" => "create", "name" => "Known #{n}"})
    identifier = "per_" <> Prima.Digest.sha256_hex("member-known-#{n}")
    user = remote!(identifier)

    assert {:ok, %{state: "added"}} =
             call(a, "member", %{
               "action" => "add",
               "athanor" => group.id,
               "identifier" => identifier
             })

    assert Members.member?(user.id, group.id)

    assert {:ok, %{state: "removed"}} =
             call(a, "member", %{
               "action" => "remove",
               "athanor" => group.id,
               "identifier" => identifier
             })

    refute Members.member?(user.id, group.id)
    assert {:ok, %{status: "active"}} = Users.get(user.id)

    assert {:ok, %{provenance: "remote", identifier: ^identifier}} =
             Arca.PersonIdentities.get(Prima.Actor.system(), user.id)
  end

  test "door.deny of an identifier withdraws the seats its invitations were holding",
       %{alice: alice, ops: ops, ctx: ctx, n: n} do
    a = ctx.(alice, Sanctum.TestContext.athanor_id(), [])
    {:ok, group} = call(a, "athanor", %{"action" => "create", "name" => "Pending id #{n}"})
    {:ok, other} = call(a, "athanor", %{"action" => "create", "name" => "Pending id 2 #{n}"})
    identifier = "per_" <> Prima.Digest.sha256_hex("pending-id-#{n}")

    for athanor <- [group, other] do
      {:ok, _} =
        call(a, "member", %{
          "action" => "add",
          "athanor" => athanor.id,
          "identifier" => identifier
        })
    end

    admin = ctx.(ops, Sanctum.TestContext.athanor_id(), platform_admin: true)

    # Nobody holds the identifier here, so the seats are the whole of what
    # the deny has to reach; the next allow seats nobody it threw out.
    assert {:ok, %{ejected: 0, invites_withdrawn: 2}} =
             call(admin, "door", %{"action" => "deny", "value" => identifier})

    for athanor <- [group, other] do
      refute Enum.any?(
               rows!(Members.list_by_athanor(athanor.id)),
               &(&1.person_identifier == identifier)
             )
    end

    assert {:error, :denied} = Sanctum.Door.admit_identifier(identifier)
  end

  test "session.use repoints the session and refuses what focus refuses",
       %{alice: alice, bob: bob, ctx: ctx, n: n} do
    a = ctx.(alice, Sanctum.TestContext.athanor_id(), [])
    {:ok, group} = call(a, "athanor", %{"action" => "create", "name" => "Switch #{n}"})

    # A seat where the session starts, so the repoint is observable.
    {:ok, _} =
      Members.ensure(alice, scope: "athanor", athanor_id: Sanctum.TestContext.athanor_id())

    {:ok, session} = Sanctum.TestContext.create_session(a)
    {:ok, loaded} = Sanctum.Session.load(session.token)
    with_hash = %{a | session_token_hash: Sanctum.Session.token_hash(session.token)}

    assert {:ok, %{athanor: %{id: gid}}} =
             call(with_hash, "session", %{"action" => "use", "athanor" => group.slug})

    assert gid == group.id
    assert loaded.athanor_id != gid
    {:ok, reloaded} = Sanctum.Session.load(session.token)
    assert reloaded.athanor_id == gid

    b = %{ctx.(bob, Sanctum.TestContext.athanor_id(), []) | session_token_hash: "x"}

    slug = group.slug

    assert {:error, {:not_found, "Athanor", ^slug}} =
             call(b, "session", %{"action" => "use", "athanor" => slug})

    k = ctx.(alice, Sanctum.TestContext.athanor_id(), auth_method: :api_key)
    assert {:error, msg} = call(k, "session", %{"action" => "use", "athanor" => group.slug})
    assert Refusals.render(msg) =~ "needs a session"
  end

  test "athanor.get and session.use answer a caller without a seat the same for an open, an archived and a missing athanor; a member hears archived",
       %{alice: alice, bob: bob, ctx: ctx, n: n} do
    a = ctx.(alice, Sanctum.TestContext.athanor_id(), [])
    {:ok, open} = call(a, "athanor", %{"action" => "create", "name" => "Open #{n}"})
    {:ok, closed} = call(a, "athanor", %{"action" => "create", "name" => "Closed #{n}"})

    {:ok, %{status: "archived"}} =
      call(a, "athanor", %{"action" => "archive", "athanor" => closed.id})

    missing = Prima.UUID7.generate_id("ath")

    b = %{ctx.(bob, Sanctum.TestContext.athanor_id(), []) | session_token_hash: "x"}

    # The refusal names what the caller named and nothing else, so with
    # the name taken out the three answers are one.
    for id <- [open.id, closed.id, missing],
        {tool, action} <- [{"athanor", "get"}, {"session", "use"}] do
      assert {:error, {:not_found, "Athanor", ^id}} =
               call(b, tool, %{"action" => action, "athanor" => id}),
             "#{tool}.#{action} told a caller with no seat something of #{id}"
    end

    # A former member is an outsider like any other.
    {:ok, _} = Members.ensure(bob, scope: "athanor", athanor_id: open.id)
    :ok = Members.remove_member(open, user_id: bob)

    assert {:error, {:not_found, "Athanor", id}} =
             call(b, "athanor", %{"action" => "get", "athanor" => open.id})

    assert id == open.id

    # The member hears that it is archived, and still reads it.
    with_hash = %{a | session_token_hash: "x"}

    assert {:error, {:invalid_argument, "That athanor is archived"}} =
             call(with_hash, "session", %{"action" => "use", "athanor" => closed.id})

    assert {:ok, %{status: "archived"}} =
             call(a, "athanor", %{"action" => "get", "athanor" => closed.id})

    assert {:error, {:invalid_argument, "That athanor is archived"}} =
             call(a, "athanor", %{"action" => "rename", "name" => "x", "athanor" => closed.id})
  end

  test "a person's own athanor has one member on every path — its owner is neither joined nor removed",
       %{alice: alice, bob: bob, ctx: ctx, n: n} do
    personal = personal!(alice)
    a = ctx.(alice, personal.id, [])
    identifier = "per_" <> Prima.Digest.sha256_hex("own-#{n}")

    for target <- [%{"user_id" => bob}, %{"identifier" => identifier}] do
      assert {:error, msg} = call(a, "member", Map.merge(%{"action" => "add"}, target))
      assert Refusals.render(msg) =~ "one member"
    end

    assert {:error, msg} = call(a, "member", %{"action" => "remove", "user_id" => alice})
    assert Refusals.render(msg) =~ "owner"
    assert Members.member?(alice, personal.id)
    assert Members.count_by_athanor(personal.id) == {:ok, 1}

    # The domain function refuses too — the tool is not the only guard.
    assert {:error, :person_athanor} = Members.add(personal, [user_id: bob], alice)
    assert {:error, :person_athanor} = Members.remove_member(personal, user_id: alice)
  end

  test "an archived athanor refuses every mutation by id, for a member and for an operator; a member reads and unarchives it, and an operator with no seat is answered as for a missing athanor",
       %{alice: alice, bob: bob, ops: ops, ctx: ctx, n: n} do
    a = ctx.(alice, Sanctum.TestContext.athanor_id(), [])
    assert {:ok, group} = call(a, "athanor", %{"action" => "create", "name" => "Closed #{n}"})
    a = ctx.(alice, group.id, [])
    assert {:ok, %{status: "archived"}} = call(a, "athanor", %{"action" => "archive"})

    operator = ctx.(ops, Sanctum.TestContext.athanor_id(), platform_admin: true)

    for {who, refused} <- [{a, "archived"}, {operator, "not found"}],
        {tool, args} <- [
          {"athanor", %{"action" => "rename", "name" => "Reopened"}},
          {"athanor",
           %{"action" => "settings", "settings" => %{"aqua" => %{"answer_mode" => "all"}}}},
          {"athanor", %{"action" => "provision"}},
          {"member", %{"action" => "add", "user_id" => bob}},
          {"member", %{"action" => "remove", "user_id" => alice}}
        ] do
      assert {:error, msg} = call(who, tool, Map.put(args, "athanor", group.id))

      assert Refusals.render(msg) =~ refused,
             "#{tool}.#{args["action"]} ran on an archived athanor"
    end

    {:ok, unchanged} = Athanors.get(group.id)
    assert unchanged.name == "Closed #{n}"

    # Reads still answer the member, whole.
    assert {:ok, %{status: "archived", member_count: 1}} =
             call(a, "athanor", %{"action" => "get", "athanor" => group.id})

    assert {:ok, %{members: [_]}} =
             call(a, "member", %{"action" => "list", "athanor" => group.id})

    # An operator who was never a member hears nothing of it, not even that
    # it is archived: their capability is over the instance, not a seat,
    # and each read answers as it does for an athanor that does not exist.
    missing = "ath_" <> Prima.UUID7.generate()

    for named <- [group.id, missing] do
      assert {:error, {:not_found, "Athanor", ^named}} =
               call(operator, "athanor", %{"action" => "get", "athanor" => named})
    end

    for {tool, action} <- [{"member", "list"}, {"athanor", "unarchive"}] do
      assert {:error, {:not_found, "Athanor", id}} =
               call(operator, tool, %{"action" => action, "athanor" => group.id}),
             "#{tool}.#{action} admitted a seatless operator"

      assert id == group.id
    end

    assert {:ok, %{status: "archived"}} = Athanors.get(group.id)

    # A member restores it.
    assert {:ok, %{status: "active"}} =
             call(a, "athanor", %{"action" => "unarchive", "athanor" => group.id})

    # Open again, it is still its members' alone: an operator with no seat
    # reads nothing of it and cannot archive it.
    for action <- ["get", "archive"] do
      assert {:error, {:not_found, "Athanor", id}} =
               call(operator, "athanor", %{"action" => action, "athanor" => group.id}),
             "athanor.#{action} admitted a seatless operator"

      assert id == group.id
    end

    assert {:ok, %{status: "active"}} = Athanors.get(group.id)

    assert {:ok, %{name: "Reopened"}} =
             call(a, "athanor", %{
               "action" => "rename",
               "name" => "Reopened",
               "athanor" => group.id
             })
  end

  test "a denied person's own athanor is archived by deny at the door and reopened by removing the deny, never by an operator's unarchive",
       %{alice: alice, ops: ops, ctx: ctx} do
    personal = personal!(alice)

    # The door verbs are the operator's platform-scope acts: they run under
    # the server's own transitions and need no seat in the athanor they
    # close and reopen.
    operator = ctx.(ops, Sanctum.TestContext.athanor_id(), platform_admin: true)

    assert {:ok, %{effect: "deny", ejected: 1, id: deny_id}} =
             call(operator, "door", %{"action" => "deny", "value" => alice})

    assert {:ok, %{status: "denied"}} = Users.get(alice)
    assert {:ok, %{status: "archived"}} = Athanors.get(personal.id)

    # The operator holds no seat in it, so unarchive and get refuse them as
    # they refuse any non-member, as for an athanor that does not exist.
    for action <- ["unarchive", "get"] do
      assert {:error, msg} =
               call(operator, "athanor", %{"action" => action, "athanor" => personal.id})

      assert Refusals.render(msg) =~ "not found"
    end

    assert {:ok, %{status: "archived"}} = Athanors.get(personal.id)

    # Removing the deny at the door reopens it and seats her in it.
    assert {:ok, %{removed: true, restored: 1}} =
             call(operator, "door", %{"action" => "remove", "id" => deny_id})

    assert {:ok, %{status: "active"}} = Users.get(alice)
    assert {:ok, %{status: "active"}} = Athanors.get(personal.id)
    assert Members.member?(alice, personal.id)
  end

  test "purge and destroy are platform-scope: an operator with no seat reclaims an archived group and learns its id and status alone, an open one answers them as a missing one does, and a member who is not an operator is refused at admission",
       %{alice: alice, ops: ops, ctx: ctx, n: n} do
    a = ctx.(alice, Sanctum.TestContext.athanor_id(), [])
    {:ok, group} = call(a, "athanor", %{"action" => "create", "name" => "Reclaim #{n}"})
    operator = ctx.(ops, Sanctum.TestContext.athanor_id(), platform_admin: true)
    refute Members.member?(ops, group.id)

    # Still open, it is its members' alone: to the seatless operator it is
    # what a missing athanor is, by id and by slug, for both verbs. A member
    # who is an operator is told to archive it first.
    missing = "ath_" <> Prima.UUID7.generate()

    for action <- ["purge", "destroy"], named <- [group.id, group.slug, missing] do
      assert {:error, {:not_found, "Athanor", ^named}} =
               call(operator, "athanor", %{"action" => action, "athanor" => named}),
             "athanor.#{action} told a seatless operator of #{named}"
    end

    seated_operator = ctx.(alice, group.id, platform_admin: true)

    assert {:error, msg} =
             call(seated_operator, "athanor", %{"action" => "purge", "athanor" => group.id})

    assert Refusals.render(msg) =~ "archive it first"

    assert {:ok, %{status: "archived"}} =
             call(a, "athanor", %{"action" => "archive", "athanor" => group.id})

    # A member who is not an operator is refused by the gate, before the
    # handler runs, for both verbs.
    for action <- ["purge", "destroy"] do
      assert {:error, %Prima.Refusal{stage: :admission, reason: :platform_admin_required}} =
               call(a, "athanor", %{"action" => action, "athanor" => group.id})
    end

    # The operator, seated nowhere in it, purges by slug and then destroys
    # by id: neither focuses the athanor, so no seat is asked for. Each
    # answers the instance's record of what it reclaimed, the id and the
    # status, and nothing the athanor held.
    assert {:ok, purged} =
             call(operator, "athanor", %{"action" => "purge", "athanor" => group.slug})

    assert purged == %{:id => group.id, :status => "archived", "purged" => true}

    assert {:ok, destroyed} =
             call(operator, "athanor", %{"action" => "destroy", "athanor" => group.id})

    # The id and status alone: no count of the rows the reclaim removed.
    assert destroyed == %{:id => group.id, :status => "archived", "destroyed" => true}

    # Only the archived tombstone survives, and nobody sits in it.
    assert {:ok, %{status: "archived"}} = Athanors.get(group.id)
    refute Members.member?(alice, group.id)

    # A person's own athanor is not destroyed here, by anyone.
    personal = personal!(alice)
    {:ok, _} = Athanors.archive(personal, force: true)

    assert {:error, msg} =
             call(operator, "athanor", %{"action" => "destroy", "athanor" => personal.id})

    assert Refusals.render(msg) =~ "own athanor is not destroyed here"
    assert {:ok, %{status: "archived"}} = Athanors.get(personal.id)
  end

  describe "athanor.pair" do
    test "mints a frozen DM with someone you share an athanor with — and finds it again",
         %{alice: alice, bob: bob, ctx: ctx, n: n} do
      a = ctx.(alice, Sanctum.TestContext.athanor_id(), [])

      # Reachability first: they must already sit in one room.
      {:ok, shared} = call(a, "athanor", %{"action" => "create", "name" => "Shared #{n}"})
      {:ok, _} = Members.ensure(bob, scope: "athanor", athanor_id: shared.id)

      assert {:ok, pair} = call(a, "athanor", %{"action" => "pair", "user" => bob})
      assert pair.kind == "group"
      assert pair.roster == "frozen"
      assert pair.member_count == 2

      # The row only — filling it is first need, so the click is instant.
      refute pair.provisioned

      # Click again (either side): the same tape, not a second one.
      b = ctx.(bob, Sanctum.TestContext.athanor_id(), [])
      assert {:ok, same} = call(b, "athanor", %{"action" => "pair", "user" => alice})
      assert same.id == pair.id
    end

    test "a stranger is unreachable — no shared athanor, no pair", %{
      alice: alice,
      bob: bob,
      ctx: ctx
    } do
      a = ctx.(alice, Sanctum.TestContext.athanor_id(), [])

      # Bob exists on this server; that is not enough. The refusal reads
      # the same as it would for an id that names nobody — the wire is not
      # a directory.
      assert {:error, {:invalid_argument, msg}} =
               call(a, "athanor", %{"action" => "pair", "user" => bob})

      assert msg =~ "already share an athanor"

      assert {:error, {:invalid_argument, ^msg}} =
               call(a, "athanor", %{
                 "action" => "pair",
                 "user" => "github|https://github.com|nobody"
               })
    end

    test "a pair is two people, and never a standing credential", %{alice: alice, ctx: ctx} do
      a = ctx.(alice, Sanctum.TestContext.athanor_id(), [])

      assert {:error, {:invalid_argument, _}} =
               call(a, "athanor", %{"action" => "pair", "user" => alice})

      # `consent: :interactive` on the annotation: the registry refuses an
      # API key before the handler runs, with the typed code.
      key = ctx.(alice, Sanctum.TestContext.athanor_id(), auth_method: :api_key)

      assert {:error,
              %Prima.Refusal{
                stage: :admission,
                reason: {:consent_class_required, {:surface_not_permitted, :api_key}}
              }} =
               call(key, "athanor", %{"action" => "pair", "user" => "github|x|other"})
    end
  end

  describe "Sanctum.Providers.Athanor.resolve/3 returns a focused context" do
    # Every downstream act (provisioning above all) must run at
    # `scope: :athanor` with the resolved athanor bound — a platform
    # context's wider scope stops at resolve, not in the handler, and only
    # a seat gets it there.
    test "a member's context is rebound to the named athanor",
         %{alice: alice, ctx: ctx, n: n} do
      a = ctx.(alice, Sanctum.TestContext.athanor_id(), [])
      assert {:ok, group} = call(a, "athanor", %{"action" => "create", "name" => "Focus #{n}"})

      assert {:ok, athanor, focused} =
               Sanctum.Providers.Athanor.resolve(a, %{"athanor" => group.id})

      assert athanor.id == group.id
      assert focused.athanor_id == group.id
      assert focused.scope == :athanor
    end

    test "a platform context narrows to an athanor its person is seated in, and opens no other",
         %{alice: alice, ops: ops, ctx: ctx, n: n} do
      a = ctx.(alice, Sanctum.TestContext.athanor_id(), [])
      assert {:ok, group} = call(a, "athanor", %{"action" => "create", "name" => "Wide #{n}"})

      operator =
        Sanctum.TestContext.platform(
          user_id: ops,
          permissions: [:*],
          auth_method: :oidc,
          platform_admin: true
        )

      # No seat: the platform scope and the capability open nothing.
      assert {:error, {:not_found, "Athanor", id}} =
               Sanctum.Providers.Athanor.resolve(operator, %{"athanor" => group.id})

      assert id == group.id

      {:ok, _} = Members.ensure(ops, scope: "athanor", athanor_id: group.id)

      assert {:ok, athanor, focused} =
               Sanctum.Providers.Athanor.resolve(operator, %{"athanor" => group.id})

      assert athanor.id == group.id
      assert focused.athanor_id == group.id
      assert focused.scope == :athanor
    end

    test "a seat the store cannot read is unavailable, never not-a-member",
         %{alice: alice, ctx: ctx, n: n} do
      a = ctx.(alice, Sanctum.TestContext.athanor_id(), [])
      assert {:ok, group} = call(a, "athanor", %{"action" => "create", "name" => "Down #{n}"})

      Arca.Repo.query!("ALTER TABLE memberships RENAME TO memberships_unavailable")

      assert {:error, {:unavailable, "Storage"}} =
               Sanctum.Providers.Athanor.resolve(a, %{"athanor" => group.id})
    end
  end

  defp rows!({:ok, rows}), do: rows

  # The person's own athanor, made with them by their admission.
  defp personal!(user_id) do
    {:ok, athanor_id} = Users.personal_athanor_id(user_id)
    {:ok, athanor} = Athanors.get(athanor_id)
    athanor
  end

  # A person whose keys another CYFR holds, admitted here under the CYFR
  # sign-in identity `identifier` names.
  defp remote!(identifier) do
    {:ok, user} =
      Sanctum.Test.People.remote(
        %{
          id: Sanctum.Auth.Identity.cyfr_key("https://dir.example", identifier),
          provider: "cyfr"
        },
        %{identifier: identifier, directory_url: "https://dir.example"}
      )

    user
  end
end
