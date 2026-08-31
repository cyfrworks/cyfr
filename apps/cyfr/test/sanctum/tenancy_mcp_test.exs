# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TenancyMCPTest do
  @moduledoc """
  The `athanor` and `member` tools — the two verbs that shape the tenancy
  fabric itself, and the only two Sanctum tools nothing called through the
  tool surface.

  Everything else here is reachable a second way (a page, a fixture, an
  underlying module with its own suite), so a broken handler shows up
  somewhere. These do not have that: `Sanctum.Tenancy.Athanors` and
  `Sanctum.Tenancy.Members` are well covered, but the ARGUMENT MAPPING
  between the wire and them — which athanor an action resolves to, who may
  name it, and what each refusal turns into — lived only here.

  What that mapping owes its callers, and what this file pins:

  - `athanor.purge` is the operator's act, and its refusal is a JSON-RPC
    authorization error (`:platform_admin_required`), not an `isError`
    content result. A client branching on `result.isError` must see the
    refusal on the transport instead.
  - An archived athanor is a hard stop on every path except the reads and
    `unarchive` that ask for it by name.
  - A person's own athanor takes no members, gives none up, and cannot be
    left; Home is never archived.
  - The person-only verbs refuse an API key with a sentence, before doing
    anything.
  """

  use ExUnit.Case, async: false

  alias Sanctum.MCP
  alias Sanctum.Tenancy.Athanors
  alias Sanctum.Tenancy.Members

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    user = "github|https://github.com|tenancy_#{System.unique_integer([:positive])}"

    ctx =
      Sanctum.Context.build(
        user_id: user,
        email: "#{System.unique_integer([:positive])}@example.com",
        provider: "github",
        namespace: "tenancyns",
        athanor_id: Athanors.home!().id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, _} = Members.ensure(user, scope: "athanor", athanor_id: Athanors.home!().id)

    {:ok, ctx: ctx, user: user}
  end

  defp group!(ctx, name \\ nil) do
    name = name || "Group #{System.unique_integer([:positive])}"
    {:ok, result} = MCP.handle("athanor", ctx, %{"action" => "create", "name" => name})
    result
  end

  # ==========================================================================
  # athanor
  # ==========================================================================

  describe "athanor.create and athanor.get" do
    test "a created group is readable by id and lists the caller as a member", %{ctx: ctx} do
      created = group!(ctx, "Bells")

      assert created.name == "Bells"

      assert {:ok, fetched} =
               MCP.handle("athanor", ctx, %{"action" => "get", "athanor" => created.id})

      assert fetched.id == created.id

      assert {:ok, %{members: [member], count: 1}} =
               MCP.handle("member", ctx, %{"action" => "list", "athanor" => created.id})

      assert member.user_id == ctx.user_id
    end

    test "create without a name is refused before anything is made", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Missing required argument: name"}} =
               MCP.handle("athanor", ctx, %{"action" => "create"})
    end

    test "an unknown action names itself rather than falling through", %{ctx: ctx} do
      assert {:error, {:unknown_action, "athanor.explode"}} =
               MCP.handle("athanor", ctx, %{"action" => "explode"})

      assert {:error, {:unknown_action, "member.explode"}} =
               MCP.handle("member", ctx, %{"action" => "explode"})
    end
  end

  describe "resolve/3 — which athanor an action gets to name" do
    test "an athanor the caller does not belong to is refused", %{ctx: ctx} do
      stranger = "github|https://github.com|stranger_#{System.unique_integer([:positive])}"

      {:ok, theirs} =
        Athanors.create_group(stranger, "Not Yours #{System.unique_integer([:positive])}")

      assert {:error, {:invalid_argument, "Not a member of that athanor"}} =
               MCP.handle("athanor", ctx, %{"action" => "get", "athanor" => theirs.id})

      assert {:error, {:invalid_argument, "Not a member of that athanor"}} =
               MCP.handle("member", ctx, %{"action" => "list", "athanor" => theirs.id})
    end

    test "an archived athanor is a hard stop except where the action asks for it", %{ctx: ctx} do
      created = group!(ctx)

      assert {:ok, %{status: "archived"}} =
               MCP.handle("athanor", ctx, %{"action" => "archive", "athanor" => created.id})

      # The reads and `unarchive` pass `include_archived: true` and still work.
      assert {:ok, %{status: "archived"}} =
               MCP.handle("athanor", ctx, %{"action" => "get", "athanor" => created.id})

      assert {:ok, _} = MCP.handle("member", ctx, %{"action" => "list", "athanor" => created.id})

      # Everything that would change it does not.
      assert {:error, _} =
               MCP.handle("athanor", ctx, %{
                 "action" => "rename",
                 "athanor" => created.id,
                 "name" => "Renamed"
               })

      assert {:error, _} =
               MCP.handle("member", ctx, %{
                 "action" => "add",
                 "athanor" => created.id,
                 "email" => "someone@example.com"
               })

      # And it reopens.
      assert {:ok, %{status: "active"}} =
               MCP.handle("athanor", ctx, %{"action" => "unarchive", "athanor" => created.id})
    end
  end

  describe "athanor.archive" do
    test "Home is the server's group and is never archived", %{ctx: ctx} do
      assert {:error, {:invalid_argument, message}} =
               MCP.handle("athanor", ctx, %{
                 "action" => "archive",
                 "athanor" => Athanors.home!().id
               })

      assert message =~ "Home is the server's group"
    end
  end

  describe "athanor.purge — the operator gate" do
    test "a member who is not the operator is refused on the transport, not in the result",
         %{ctx: ctx} do
      created = group!(ctx)
      MCP.handle("athanor", ctx, %{"action" => "archive", "athanor" => created.id})

      # `:platform_admin_required` is what `Sanctum.Unauthorized` recognises,
      # so the router answers a JSON-RPC error rather than an `isError`
      # content result. Anything else here — a sentence, an
      # `{:invalid_argument, _}` — would put an authorization failure back
      # inside a successful response.
      assert {:error, :platform_admin_required} =
               MCP.handle("athanor", ctx, %{"action" => "purge", "athanor" => created.id})

      assert Sanctum.Unauthorized.reason?(:platform_admin_required),
             "the purge refusal is no longer on the shared authorization vocabulary"
    end

    test "the operator may purge, but only what is archived", %{ctx: ctx, user: user} do
      created = group!(ctx)
      admin = %{ctx | platform_admin: true}

      assert {:error, {:invalid_argument, message}} =
               MCP.handle("athanor", admin, %{"action" => "purge", "athanor" => created.id})

      assert message =~ "archive it first"

      MCP.handle("athanor", ctx, %{"action" => "archive", "athanor" => created.id})

      assert {:ok, purged} =
               MCP.handle("athanor", admin, %{"action" => "purge", "athanor" => created.id})

      assert purged["purged"] == true

      # Purging takes the blobs, not the row: the athanor is still there and
      # still the caller's.
      assert Members.member?(user, created.id)
    end
  end

  # ==========================================================================
  # member
  # ==========================================================================

  describe "member.add" do
    test "an address nobody has signed in with yet is seated all the same", %{ctx: ctx} do
      created = group!(ctx)

      assert {:ok, %{member: %{email: "newcomer@example.com"}, state: "added"}} =
               MCP.handle("member", ctx, %{
                 "action" => "add",
                 "athanor" => created.id,
                 "email" => "Newcomer@Example.com"
               })
    end

    test "a target that is neither an email nor a user id is refused", %{ctx: ctx} do
      created = group!(ctx)

      assert {:error, {:invalid_argument, "Missing required argument: email or user_id"}} =
               MCP.handle("member", ctx, %{"action" => "add", "athanor" => created.id})

      assert {:error, {:invalid_argument, "That is not an email address"}} =
               MCP.handle("member", ctx, %{
                 "action" => "add",
                 "athanor" => created.id,
                 "email" => "not-an-email"
               })
    end
  end

  describe "member.remove and member.leave" do
    test "removing someone who is not there names them", %{ctx: ctx} do
      created = group!(ctx)

      assert {:error, {:not_found, "Member", "ghost@example.com"}} =
               MCP.handle("member", ctx, %{
                 "action" => "remove",
                 "athanor" => created.id,
                 "email" => "Ghost@Example.com"
               })
    end

    test "leaving a group gives up the seat, and the last one out archives it",
         %{ctx: ctx, user: user} do
      created = group!(ctx)
      assert Members.member?(user, created.id)

      assert {:ok, %{state: "left"}} =
               MCP.handle("member", ctx, %{"action" => "leave", "athanor" => created.id})

      refute Members.member?(user, created.id)

      # `Members.remove_member/2` archives a group nobody is left in, so the
      # second attempt is stopped by the archive rather than by the missing
      # seat — a group with no members is not a group anyone can act in.
      assert {:ok, %{status: "archived"}} =
               MCP.handle("athanor", %{ctx | platform_admin: true}, %{
                 "action" => "get",
                 "athanor" => created.id
               })

      assert {:error, {:invalid_argument, "That athanor is archived"}} =
               MCP.handle("member", ctx, %{"action" => "leave", "athanor" => created.id})
    end

    test "a person's own athanor takes no members and cannot be left" do
      n = System.unique_integer([:positive])

      {:ok, user} =
        Sanctum.Tenancy.Users.upsert_from_provider(%{
          id: "github|https://github.com|own-#{n}",
          provider: "github",
          email: "own#{n}@example.com",
          verified: true,
          name: "Own #{n}"
        })

      {:ok, user} = Sanctum.Tenancy.Users.set_namespace(user, "own#{n}")
      {:ok, own} = Sanctum.Provisioning.ensure_personal_athanor(user)
      assert own.kind == "person"

      ctx =
        Sanctum.Context.build(
          user_id: user.id,
          email: user.email,
          provider: "github",
          namespace: user.namespace,
          athanor_id: own.id,
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )

      assert {:error, {:invalid_argument, "You cannot leave your own athanor"}} =
               MCP.handle("member", ctx, %{"action" => "leave", "athanor" => own.id})

      assert {:error, {:invalid_argument, message}} =
               MCP.handle("member", ctx, %{
                 "action" => "add",
                 "athanor" => own.id,
                 "email" => "someone@example.com"
               })

      assert message =~ "add people to a group"

      assert {:error, {:invalid_argument, remove_message}} =
               MCP.handle("member", ctx, %{
                 "action" => "remove",
                 "athanor" => own.id,
                 "user_id" => user.id
               })

      assert remove_message =~ "cannot remove the owner"
    end
  end

  describe "the person-only verbs and an API key" do
    test "an API key is refused with a sentence, before the athanor is even resolved", %{ctx: ctx} do
      key_ctx = %{ctx | auth_method: :api_key}

      for action <- ["add", "remove", "leave"] do
        assert {:error, {:invalid_argument, message}} =
                 MCP.handle("member", key_ctx, %{
                   "action" => action,
                   "athanor" => "ath_does_not_exist",
                   "email" => "someone@example.com"
                 })

        assert message == "member.#{action} is a person's act — sign in; an API key cannot do it",
               "member.#{action} let an API key through"
      end

      # A read is not a person's act, so the key still gets it.
      assert {:ok, _} = MCP.handle("member", key_ctx, %{"action" => "list"})
    end
  end
end
