# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP.AthanorMemberDoorToolsTest do
  @moduledoc """
  The tenancy verbs through the MCP registry: `athanor.*`, `member.*` and
  `door.*` — who may call them, what they answer, and what they never leak.
  """
  use ExUnit.Case, async: false

  alias Emissary.MCP.ToolRegistry
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    original = Application.get_env(:cyfr, :platform_admin_emails, [])
    Application.put_env(:cyfr, :platform_admin_emails, ["ops@example.com"])
    on_exit(fn -> Application.put_env(:cyfr, :platform_admin_emails, original) end)

    n = System.unique_integer([:positive])
    alice = "github|https://github.com|alice-#{n}"
    bob = "github|https://github.com|bob-#{n}"
    ops = "github|https://github.com|ops-#{n}"

    for {id, email} <- [{alice, "alice#{n}@example.com"}, {bob, "bob#{n}@example.com"}] do
      {:ok, _} =
        Users.upsert_from_provider(%{id: id, provider: "github", email: email, verified: true})
    end

    {:ok, _} = Members.ensure_platform(ops)

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

  defp call(ctx, tool, args), do: ToolRegistry.call_external(tool, ctx, args)

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

    # a non-member cannot act on it
    assert {:error, msg} =
             call(b, "member", %{"action" => "list", "athanor" => group.id})

    assert msg =~ "Not a member"

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

  test "member.add answers the same for a stranger's email and a known one, and never opens the door",
       %{alice: alice, bob: bob, ctx: ctx, n: n} do
    a = ctx.(alice, Sanctum.TestContext.athanor_id(), [])
    {:ok, group} = call(a, "athanor", %{"action" => "create", "name" => "Team #{n}"})

    stranger = "stranger#{n}@example.com"

    assert {:ok, %{state: "added", member: %{email: ^stranger}}} =
             call(a, "member", %{"action" => "add", "athanor" => group.id, "email" => stranger})

    known = "bob#{n}@example.com"

    assert {:ok, %{state: "added", member: %{email: ^known}}} =
             call(a, "member", %{"action" => "add", "athanor" => group.id, "email" => known})

    # bob (known, verified) is active at once; the stranger sits invited
    assert Members.member?(bob, group.id)
    assert Enum.any?(Members.list_by_athanor(group.id), &(&1.status == "invited" and &1.email == stranger))

    # and the door queued a request rather than admitting anyone
    assert [%{value: ^stranger, status: "requested"}] = Sanctum.Door.Store.requests()

    assert {:error, :not_allowed} =
             Sanctum.Door.admit("github|https://github.com|s", stranger, true)
  end

  test "an API key cannot create groups or add members", %{alice: alice, ctx: ctx} do
    k = ctx.(alice, Sanctum.TestContext.athanor_id(), auth_method: :api_key)

    assert {:error, msg} = call(k, "athanor", %{"action" => "create", "name" => "Nope"})
    assert msg =~ "person's act"
    assert {:error, msg} = call(k, "member", %{"action" => "add", "email" => "x@example.com"})
    assert msg =~ "person's act"
    # reads are fine
    assert {:ok, %{athanors: _}} = call(k, "athanor", %{"action" => "list"})
  end

  test "Home cannot be archived; a person's own athanor cannot be archived here",
       %{alice: alice, ctx: ctx, n: n} do
    home = Athanors.home!()
    {:ok, _} = Members.ensure(alice, scope: "athanor", athanor_id: home.id)
    a = ctx.(alice, home.id, [])
    assert {:error, msg} = call(a, "athanor", %{"action" => "archive"})
    assert msg =~ "Home"

    {:ok, personal} =
      Athanors.create(%{
        kind: "person",
        name: "Alice",
        slug: "alice#{n}",
        owner_user_id: alice,
        created_by: alice
      })

    {:ok, _} = Members.ensure(alice, scope: "athanor", athanor_id: personal.id)
    assert {:error, msg} = call(a, "athanor", %{"action" => "archive", "athanor" => personal.id})
    assert msg =~ "own athanor"
    assert {:error, msg} = call(a, "member", %{"action" => "leave", "athanor" => personal.id})
    assert msg =~ "own athanor"
  end

  test "door.* is the operator's: refused for a member, hidden from tools/list, open to an admin",
       %{alice: alice, ops: ops, ctx: ctx, n: n} do
    member = ctx.(alice, Sanctum.TestContext.athanor_id(), [])
    assert {:error, msg} = call(member, "door", %{"action" => "list"})
    assert msg =~ "platform admin required"

    admin = ctx.(ops, Athanors.home!().id, platform_admin: true)
    assert {:ok, %{entries: []}} = call(admin, "door", %{"action" => "list"})

    email = "carol#{n}@example.com"

    assert {:ok, %{kind: "email", effect: "allow"}} =
             call(admin, "door", %{"action" => "allow", "value" => email, "note" => "friend"})

    assert {:ok, %{kind: "wildcard"}} =
             call(admin, "door", %{"action" => "allow", "value" => "*"})

    assert {:ok, :allowed} = Sanctum.Door.admit("github|https://github.com|c", email, true)

    # deny ejects a known person and is sticky against *
    {:ok, _} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|carol-#{n}",
        provider: "github",
        email: email,
        verified: true
      })

    assert {:ok, %{effect: "deny", ejected: 1}} =
             call(admin, "door", %{"action" => "deny", "value" => email})

    assert {:error, :denied} = Sanctum.Door.admit("github|https://github.com|c", email, true)
    assert {:ok, %{status: "denied"}} = Users.get("github|https://github.com|carol-#{n}")

    # an operator email cannot be denied
    assert {:error, msg} =
             call(admin, "door", %{"action" => "deny", "value" => "ops@example.com"})

    assert msg =~ "platform admin"

    # allowing again reverses the standing
    assert {:ok, _} = call(admin, "door", %{"action" => "allow", "value" => email})
    assert {:ok, %{status: "active"}} = Users.get("github|https://github.com|carol-#{n}")

    # so does removing a deny entry — nobody is left denied with no entry to say why
    assert {:ok, %{effect: "deny", id: deny_id}} =
             call(admin, "door", %{"action" => "deny", "value" => email})

    assert {:ok, %{status: "denied"}} = Users.get("github|https://github.com|carol-#{n}")
    assert {:ok, %{removed: true}} = call(admin, "door", %{"action" => "remove", "id" => deny_id})
    assert {:ok, %{status: "active"}} = Users.get("github|https://github.com|carol-#{n}")
    assert {:ok, :allowed} = Sanctum.Door.admit("github|https://github.com|c", email, true)
  end

  test "session.use repoints the session and refuses what focus refuses",
       %{alice: alice, bob: bob, ctx: ctx, n: n} do
    a = ctx.(alice, Sanctum.TestContext.athanor_id(), [])
    {:ok, group} = call(a, "athanor", %{"action" => "create", "name" => "Switch #{n}"})

    {:ok, session} = Sanctum.Session.create(a)
    {:ok, loaded} = Sanctum.Session.load(session.token, surface: :console)
    with_hash = %{a | session_token_hash: Sanctum.Session.token_hash(session.token)}

    assert {:ok, %{athanor: %{id: gid}}} =
             call(with_hash, "session", %{"action" => "use", "athanor" => group.slug})

    assert gid == group.id
    assert loaded.athanor_id != gid
    {:ok, reloaded} = Sanctum.Session.load(session.token, surface: :console)
    assert reloaded.athanor_id == gid

    b = %{ctx.(bob, Sanctum.TestContext.athanor_id(), []) | session_token_hash: "x"}
    assert {:error, msg} = call(b, "session", %{"action" => "use", "athanor" => group.slug})
    assert msg =~ "Not a member"

    k = ctx.(alice, Sanctum.TestContext.athanor_id(), auth_method: :api_key)
    assert {:error, msg} = call(k, "session", %{"action" => "use", "athanor" => group.slug})
    assert msg =~ "needs a session"
  end
end
