# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ContextFocusTest do
  @moduledoc """
  Focus narrows everyone, admins included: a request context works inside
  one athanor, and only one its person holds a seat in. Being a platform
  admin is a capability over the instance that admits the platform-scope
  operations — never a seat, and never a wider tenant scope.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    alice = "github|https://github.com|alice-#{System.unique_integer([:positive])}"
    ops = "github|https://github.com|ops-#{System.unique_integer([:positive])}"
    {:ok, a} = Athanors.create_group(alice, "A group")
    {:ok, b} = Athanors.create_group("github|https://github.com|someone", "B group")
    {:ok, _} = Members.ensure_platform(ops)

    ctx = fn user_id, athanor_id, admin? ->
      Context.build(
        user_id: user_id,
        athanor_id: athanor_id,
        provider: "github",
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true,
        platform_admin: admin?
      )
    end

    {:ok, a: a, b: b, alice: alice, ops: ops, ctx: ctx}
  end

  test "a member focuses their athanor; a non-member is refused", %{
    a: a,
    b: b,
    alice: alice,
    ctx: ctx
  } do
    c = ctx.(alice, nil, false)
    assert {:ok, focused} = Context.focus(c, a.id)
    assert focused.athanor_id == a.id
    assert focused.scope == :athanor
    assert {:error, :not_member} = Context.focus(c, b)
    assert {:error, :not_found} = Context.focus(c, "ath_nope")
  end

  test "an archived athanor cannot be focused", %{a: a, alice: alice, ctx: ctx} do
    {:ok, archived} = Athanors.archive(a)
    assert {:error, :archived} = Context.focus(ctx.(alice, nil, false), archived)
  end

  test "a stale copy of the row is read for its id alone: focus rereads the standing",
       %{a: a, alice: alice, ctx: ctx} do
    {:ok, before_archive} = Athanors.get(a.id)
    {:ok, _} = Athanors.archive(a)

    # The copy still says active; the row it names does not.
    assert before_archive.status == "active"
    assert {:error, :archived} = Context.focus(ctx.(alice, nil, false), before_archive)

    # A map that only names the id is as good as the id, and a forged
    # status on it decides nothing.
    assert {:error, :archived} =
             Context.focus(ctx.(alice, nil, false), %{id: a.id, status: "active"})
  end

  test "a store that cannot answer is unavailable, never an absence or a refusal",
       %{a: a, alice: alice, ctx: ctx} do
    c = ctx.(alice, nil, false)

    Arca.Repo.query!("ALTER TABLE memberships RENAME TO memberships_unavailable")
    assert {:error, :unavailable} = Context.focus(c, a.id)
    Arca.Repo.query!("ALTER TABLE memberships_unavailable RENAME TO memberships")

    Arca.Repo.query!("ALTER TABLE athanors RENAME TO athanors_unavailable")
    assert {:error, :unavailable} = Context.focus(c, a.id)
    assert {:error, :unavailable} = Context.focus(c, a)

    sys = Sanctum.internal_context(user_id: "_test", athanor_id: a.id, scope: :athanor)
    assert {:error, :unavailable} = Context.refocus(sys, a.id)
  end

  test "refocus is focus for a person, and an archive-checked crossing for the system plane",
       %{a: a, b: b, alice: alice, ctx: ctx} do
    # A person's refocus IS focus: member in, non-member out.
    c = ctx.(alice, nil, false)
    assert {:ok, %{athanor_id: id}} = Context.refocus(c, a.id)
    assert id == a.id
    assert {:error, :not_member} = Context.refocus(c, b.id)

    # The system plane crosses tenants by design (recovery resolving a
    # stored agent has no member to speak as) — but a closed furnace stays
    # closed to it too.
    sys = Sanctum.internal_context(user_id: "_test", athanor_id: a.id, scope: :athanor)
    assert {:ok, %{athanor_id: bid, scope: :athanor} = crossed} = Context.refocus(sys, b.id)
    assert bid == b.id

    # The actor it projects keeps the system provenance and still reads one
    # athanor: the two authorities Arca decides on are separate, and a
    # crossing narrows the scope without giving up the system write.
    assert Context.actor(crossed).system
    assert Context.actor(crossed).scope == :athanor

    {:ok, _} = Athanors.archive(b)
    assert {:error, :archived} = Context.refocus(sys, b.id)
    assert {:error, :not_found} = Context.refocus(sys, "ath_nope")

    # No athanor at all — an id read off a record that had none — is the
    # spec's refusal, not a clause error.
    assert {:error, :not_found} = Context.refocus(sys, nil)
    assert {:error, :not_found} = Context.refocus(c, nil)
  end

  test "a platform administrator without a seat cannot focus an athanor",
       %{a: a, b: b, alice: alice, ops: ops, ctx: ctx} do
    {:ok, personal} =
      Athanors.create(%{
        kind: "person",
        name: "Alice",
        slug: "alice-#{System.unique_integer([:positive])}",
        owner_user_id: alice,
        created_by: alice
      })

    {:ok, _} = Members.ensure(alice, scope: "athanor", athanor_id: personal.id)

    handler = "focus-test-#{System.unique_integer([:positive])}"
    parent = self()

    # This case's own process alone: another module's internal contexts
    # are built beside it.
    :telemetry.attach(
      handler,
      [:cyfr, :sanctum, :platform_context],
      fn _e, _m, meta, _c -> if self() == parent, do: send(parent, {:audit, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    admin = ctx.(ops, nil, true)
    assert admin.platform_admin

    # A group, another person's own athanor: the capability is no seat in
    # either, so focus refuses the operator exactly as it refuses anyone.
    for athanor <- [a, b, personal] do
      assert {:error, :not_member} = Context.focus(admin, athanor)
      assert {:error, :not_member} = Context.focus(admin, athanor.id)
      assert {:error, :not_member} = Context.refocus(admin, athanor.id)
    end

    # Refused, and audited by nothing: no open is recorded, because none
    # happened.
    refute_received {:audit, _}

    # A platform context of the same person is no way round it either.
    platform =
      Sanctum.TestContext.platform(
        user_id: ops,
        permissions: [:*],
        auth_method: :oidc,
        platform_admin: true
      )

    assert_received {:audit, %{sanctioned: true, user_id: ^ops}}
    assert {:error, :not_member} = Context.focus(platform, b)
    refute_received {:audit, _}
  end

  test "an administrator who left a group cannot focus it, and their session falls back to their own athanor",
       %{a: a, ctx: ctx} do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|ops-own-#{n}",
        provider: "github",
        email: "ops-own#{n}@example.com",
        verified: true
      })

    {:ok, own} =
      Athanors.create(%{
        kind: "person",
        name: "Ops",
        slug: "ops-own-#{n}",
        owner_user_id: user.id,
        created_by: user.id
      })

    {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: own.id)
    {:ok, _} = Users.set_personal_athanor(user, own.id)
    {:ok, _} = Members.ensure_platform(user.id)
    {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: a.id)

    admin = ctx.(user.id, nil, true)
    assert {:ok, %{athanor_id: focused}} = Context.focus(admin, a)
    assert focused == a.id

    # They leave; alice stays, so the group stays open.
    :ok = Members.remove_member(a, user_id: user.id)
    assert {:ok, %{status: "active"}} = Athanors.get(a.id)

    assert {:error, :not_member} = Context.focus(admin, a)

    # A session still naming the group is moved on its next revalidation to
    # their own athanor: the capability stays, and keeps them in no other.
    {:ok, revalidated} = Sanctum.Tenancy.revalidate(ctx.(user.id, a.id, true))
    assert revalidated.athanor_id == own.id
    assert revalidated.platform_admin
    assert revalidated.scope == :athanor
  end

  test "a member focused on A cannot read B's records, operator or not — no scope bypass",
       %{a: a, b: b, ops: ops, ctx: ctx} do
    # The operator holds a seat in A: a member like any other, whose
    # capability widens nothing.
    {:ok, _} = Members.ensure(ops, scope: "athanor", athanor_id: a.id)
    {:ok, focused} = Context.focus(ctx.(ops, nil, true), a)
    assert focused.platform_admin

    # The actor an Arca facade receives carries neither authority: the rows
    # it reads are the focused athanor's.
    assert Context.actor(focused).scope == :athanor
    refute Context.actor(focused).system

    assert :ok = Context.authorize(focused, :read, {:tenant, %{athanor_id: a.id}})
    assert {:error, _} = Context.authorize(focused, :read, {:tenant, %{athanor_id: b.id}})
    assert {:error, _} = Sanctum.TenantPolicy.verify(focused, %{athanor_id: b.id})

    query =
      Arca.QueryHelpers.where_tenant_unless_platform(
        Arca.Schemas.Execution,
        Context.actor(focused)
      )

    assert inspect(query) =~ "athanor_id"
  end

  test "a member focused on A cannot reach B's execution or files through the tools either, operator or not",
       %{a: a, b: b, ops: ops, ctx: ctx} do
    {:ok, _} = Members.ensure(ops, scope: "athanor", athanor_id: a.id)
    {:ok, focused} = Context.focus(ctx.(ops, nil, true), a)
    b_exec = "exec_b_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Arca.Execution.record_start(%{
        id: b_exec,
        reference: "formula:local.test:1.0.0",
        user_id: "github|https://github.com|someone",
        athanor_id: b.id,
        started_at: DateTime.utc_now(),
        status: "running",
        component_type: "formula"
      })

    b_ctx = ctx.("github|https://github.com|someone", b.id, false)
    :ok = Arca.put(Sanctum.Context.actor(b_ctx), ["data", "secret.txt"], "b's bytes")

    # the audit ledger of B is invisible from A
    assert {:error, msg} =
             Grimoire.call_external("record", focused, %{
               "action" => "get",
               "id" => b_exec
             })

    assert err_msg(msg) =~ "not found"

    assert {:ok, %{executions: listed}} =
             Grimoire.call_external("record", focused, %{"action" => "list"})

    refute Enum.any?(listed, &(&1.id == b_exec))

    # and so is B's storage: a URI is rooted in the focused athanor, never another
    read = %{"action" => "read", "uri" => "arca://files/data/secret.txt"}

    assert {:error, {:not_found, "File", _}} =
             Grimoire.call_external("resource", focused, read)

    assert {:ok, %{content: content}} = Grimoire.call_external("resource", b_ctx, read)

    assert Base.decode64!(content) == "b's bytes"
  end

  test "resolve_status gives an admin the capability, an :athanor scope, and their own athanor",
       %{ops: ops} do
    {:ok, athanor} = Athanors.create_group(ops, "Ops #{System.unique_integer([:positive])}")
    {:ok, _} = Members.ensure(ops, scope: "athanor", athanor_id: athanor.id)

    {:ok, resolved} =
      Sanctum.Tenancy.resolve_status(
        %Context{user_id: ops, athanor_id: nil, permissions: MapSet.new()},
        force: true
      )

    assert resolved.platform_admin
    assert resolved.scope == :athanor
    assert resolved.athanor_id == athanor.id
  end

  test "revalidate keeps a granted athanor and re-derives the capability", %{
    a: a,
    alice: alice,
    ctx: ctx
  } do
    c = ctx.(alice, a.id, true)
    {:ok, out} = Sanctum.Tenancy.revalidate(c)
    assert out.athanor_id == a.id
    refute out.platform_admin

    :ok = Members.remove_member(a, user_id: alice)
    {:ok, out} = Sanctum.Tenancy.revalidate(c)
    assert out.athanor_id == nil
  end

  # Providers answer typed reasons where the class is clear; the shared
  # renderer is the one spelling of every sentence, so assert through it.
  # Plain strings pass through unchanged.
  defp err_msg(reason) do
    Grimoire.Error.render(reason) ||
      flunk("unrenderable refusal: #{inspect(reason)}")
  end
end
