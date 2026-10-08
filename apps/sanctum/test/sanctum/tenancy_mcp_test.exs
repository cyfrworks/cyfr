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

  - `athanor.purge` and `athanor.destroy` are the operator's platform-scope
    operations: declared `scope: :platform`, so the dispatch gate refuses
    anyone else with `:platform_admin_required`, a JSON-RPC authorization
    error rather than an `isError` content result, before the handler runs
    (the refusal through the gate is pinned in
    `Sanctum.Providers.AthanorMemberDoorToolsTest`). The handler names its
    athanor explicitly and never reads the one in focus.
  - An archived athanor is a hard stop on every path except the reads and
    `unarchive` that ask for it by name, and those are a member's; an
    operator with no seat reads its public facts alone.
  - A person's own athanor takes no members, gives none up, and cannot be
    left.
  - The person-only verbs refuse an API key with a sentence, before doing
    anything.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Provider
  alias Sanctum.Tenancy.Athanors
  alias Sanctum.Tenancy.Members

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    user = "github|https://github.com|tenancy_#{System.unique_integer([:positive])}"
    {:ok, athanor} = Athanors.create_group(user, "Tenancy #{System.unique_integer([:positive])}")

    ctx =
      Sanctum.Context.build(
        user_id: user,
        email: "#{System.unique_integer([:positive])}@example.com",
        provider: "github",
        namespace: "tenancyns",
        athanor_id: athanor.id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, _} = Members.ensure(user, scope: "athanor", athanor_id: athanor.id)

    {:ok, ctx: ctx, user: user, athanor: athanor}
  end

  defp group!(ctx, name \\ nil) do
    name = name || "Group #{System.unique_integer([:positive])}"
    {:ok, result} = Provider.handle("athanor", ctx, %{"action" => "create", "name" => name})
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
               Provider.handle("athanor", ctx, %{"action" => "get", "athanor" => created.id})

      assert fetched.id == created.id

      assert {:ok, %{members: [member], count: 1}} =
               Provider.handle("member", ctx, %{"action" => "list", "athanor" => created.id})

      assert member.user_id == ctx.user_id
    end

    test "create without a name is refused before anything is made", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Missing required argument: name"}} =
               Provider.handle("athanor", ctx, %{"action" => "create"})
    end

    test "an unknown action names itself rather than falling through", %{ctx: ctx} do
      assert {:error, {:unknown_action, "athanor.explode"}} =
               Provider.handle("athanor", ctx, %{"action" => "explode"})

      assert {:error, {:unknown_action, "member.explode"}} =
               Provider.handle("member", ctx, %{"action" => "explode"})
    end
  end

  describe "resolve/3 — which athanor an action gets to name" do
    test "an athanor the caller does not belong to is refused", %{ctx: ctx} do
      stranger = "github|https://github.com|stranger_#{System.unique_integer([:positive])}"

      {:ok, theirs} =
        Athanors.create_group(stranger, "Not Yours #{System.unique_integer([:positive])}")

      assert {:error, {:invalid_argument, "Not a member of that athanor"}} =
               Provider.handle("athanor", ctx, %{"action" => "get", "athanor" => theirs.id})

      assert {:error, {:invalid_argument, "Not a member of that athanor"}} =
               Provider.handle("member", ctx, %{"action" => "list", "athanor" => theirs.id})
    end

    test "an archived athanor is a hard stop except where the action asks for it", %{ctx: ctx} do
      created = group!(ctx)

      assert {:ok, %{status: "archived"}} =
               Provider.handle("athanor", ctx, %{"action" => "archive", "athanor" => created.id})

      # The reads and `unarchive` pass `include_archived: true` and still work.
      assert {:ok, %{status: "archived"}} =
               Provider.handle("athanor", ctx, %{"action" => "get", "athanor" => created.id})

      assert {:ok, _} =
               Provider.handle("member", ctx, %{"action" => "list", "athanor" => created.id})

      # Everything that would change it does not.
      assert {:error, _} =
               Provider.handle("athanor", ctx, %{
                 "action" => "rename",
                 "athanor" => created.id,
                 "name" => "Renamed"
               })

      assert {:error, _} =
               Provider.handle("member", ctx, %{
                 "action" => "add",
                 "athanor" => created.id,
                 "email" => "someone@example.com"
               })

      # And it reopens.
      assert {:ok, %{status: "active"}} =
               Provider.handle("athanor", ctx, %{"action" => "unarchive", "athanor" => created.id})
    end
  end

  describe "athanor.purge and athanor.destroy — the platform scope" do
    test "are declared platform-scope, which the gate refuses a non-operator on the transport" do
      scopes =
        for %{tool: "athanor", action: action, scope: scope} <-
              Sanctum.Providers.Athanor.definition().operations,
            into: %{},
            do: {action, scope}

      # The two reclaiming verbs, and no other: everything else the tool
      # does is a member's act in an athanor they hold a seat in.
      assert for({action, :platform} <- scopes, do: action) |> Enum.sort() == ["destroy", "purge"]

      # `:platform_admin_required` is what `Sanctum.Unauthorized` recognises,
      # so the router answers the gate's refusal as a JSON-RPC error rather
      # than an `isError` content result.
      assert Sanctum.Unauthorized.reason?(:platform_admin_required),
             "the purge refusal is no longer on the shared authorization vocabulary"
    end

    test "the operator may purge, but only what is archived", %{ctx: ctx, user: user} do
      created = group!(ctx)
      admin = %{ctx | platform_admin: true}

      assert {:error, {:invalid_argument, message}} =
               Provider.handle("athanor", admin, %{"action" => "purge", "athanor" => created.id})

      assert message =~ "archive it first"

      Provider.handle("athanor", ctx, %{"action" => "archive", "athanor" => created.id})

      assert {:ok, purged} =
               Provider.handle("athanor", admin, %{"action" => "purge", "athanor" => created.id})

      assert purged["purged"] == true

      # Purging takes the blobs, not the row: the athanor is still there and
      # still the caller's.
      assert Members.member?(user, created.id)
    end

    test "name their athanor and never read the one in focus", %{ctx: ctx} do
      admin = %{ctx | platform_admin: true}

      # The operator works in an athanor of their own; a platform operation
      # acts on what it names and nothing else.
      for action <- ["purge", "destroy"] do
        assert {:error, {:invalid_argument, "No athanor in focus — pass athanor"}} =
                 Provider.handle("athanor", admin, %{"action" => action})
      end

      assert {:ok, %{status: "active"}} = Athanors.get(ctx.athanor_id)
    end
  end

  # ==========================================================================
  # member
  # ==========================================================================

  describe "member.add" do
    test "an address nobody has signed in with yet is seated all the same", %{ctx: ctx} do
      created = group!(ctx)

      assert {:ok, %{member: %{email: "newcomer@example.com"}, state: "added"}} =
               Provider.handle("member", ctx, %{
                 "action" => "add",
                 "athanor" => created.id,
                 "email" => "Newcomer@Example.com"
               })
    end

    test "a target that is neither an email nor a user id is refused", %{ctx: ctx} do
      created = group!(ctx)

      assert {:error,
              {:invalid_argument, "Missing required argument: email, user_id or identifier"}} =
               Provider.handle("member", ctx, %{"action" => "add", "athanor" => created.id})

      assert {:error, {:invalid_argument, "That is not an email address"}} =
               Provider.handle("member", ctx, %{
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
               Provider.handle("member", ctx, %{
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
               Provider.handle("member", ctx, %{"action" => "leave", "athanor" => created.id})

      refute Members.member?(user, created.id)

      # `Members.remove_member/2` archives a group nobody is left in, so the
      # second attempt is stopped by the archive rather than by the missing
      # seat — a group with no members is not a group anyone can act in.
      # The former member reads nothing of it; an operator, who holds no
      # seat either, reads its public facts and nothing it holds.
      assert {:error, {:invalid_argument, "Not a member of that athanor"}} =
               Provider.handle("athanor", ctx, %{"action" => "get", "athanor" => created.id})

      test = self()
      handler = "tenancy-mcp-facts-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          fn _event, _measurements, meta, _config ->
            if self() == test and is_binary(meta[:source]),
              do: send(test, {:read, meta[:source]})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, %{status: "archived"} = facts} =
               Provider.handle("athanor", %{ctx | platform_admin: true}, %{
                 "action" => "get",
                 "athanor" => created.id
               })

      :telemetry.detach(handler)

      assert Map.keys(facts) |> Enum.sort() == [:archived_at, :id, :name, :status]
      assert %DateTime{} = facts.archived_at

      # The row and the seat check, and nothing the athanor holds: no
      # thread, file, vault or member list is read for the answer.
      assert Enum.reject(reads(), &(&1 in ["athanors", "memberships"])) == []

      assert {:error, {:invalid_argument, "That athanor is archived"}} =
               Provider.handle("member", ctx, %{"action" => "leave", "athanor" => created.id})
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
               Provider.handle("member", ctx, %{"action" => "leave", "athanor" => own.id})

      assert {:error, {:invalid_argument, message}} =
               Provider.handle("member", ctx, %{
                 "action" => "add",
                 "athanor" => own.id,
                 "email" => "someone@example.com"
               })

      assert message =~ "add people to a group"

      assert {:error, {:invalid_argument, remove_message}} =
               Provider.handle("member", ctx, %{
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
                 Provider.handle("member", key_ctx, %{
                   "action" => action,
                   "athanor" => "ath_does_not_exist",
                   "email" => "someone@example.com"
                 })

        assert message == "member.#{action} is a person's act — sign in; an API key cannot do it",
               "member.#{action} let an API key through"
      end

      # A read is not a person's act, so the key still gets it.
      assert {:ok, _} = Provider.handle("member", key_ctx, %{"action" => "list"})
    end
  end

  # The tables a case's own statements read, in order.
  defp reads(acc \\ []) do
    receive do
      {:read, source} -> reads([source | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
