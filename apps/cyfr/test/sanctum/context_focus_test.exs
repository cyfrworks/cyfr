# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ContextFocusTest do
  @moduledoc """
  Focus narrows everyone, admins included: a request context works inside
  one athanor, and being a platform admin is a capability that admits the
  operator verbs and an audited open — never a wider tenant scope.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Members}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

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

  test "a platform admin may open any athanor — audited, still :athanor scope",
       %{b: b, ops: ops, ctx: ctx} do
    handler = "focus-test-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:cyfr, :sanctum, :platform_context],
      fn _e, _m, meta, _c -> send(parent, {:audit, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, focused} = Context.focus(ctx.(ops, nil, true), b)
    assert focused.athanor_id == b.id
    assert focused.scope == :athanor
    assert focused.platform_admin
    assert_receive {:audit, %{caller: :focus, athanor_id: bid}}
    assert bid == b.id
  end

  test "an admin focused on A cannot read B's records — no scope bypass",
       %{a: a, b: b, ops: ops, ctx: ctx} do
    {:ok, focused} = Context.focus(ctx.(ops, nil, true), a)
    assert :ok = Context.authorize(focused, :read, {:tenant, %{athanor_id: a.id}})
    assert {:error, _} = Context.authorize(focused, :read, {:tenant, %{athanor_id: b.id}})
    assert {:error, _} = Sanctum.TenantPolicy.verify(focused, %{athanor_id: b.id})

    query = Arca.QueryHelpers.where_tenant_unless_platform(Arca.Execution, focused)
    assert inspect(query) =~ "athanor_id"
  end

  test "an admin focused on A cannot reach B's execution or files through the tools either",
       %{a: a, b: b, ops: ops, ctx: ctx} do
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
    :ok = Arca.put(b_ctx, ["data", "secret.txt"], "b's bytes")

    # the audit ledger of B is invisible from A
    assert {:error, msg} =
             Emissary.MCP.ToolRegistry.call_external("record", focused, %{
               "action" => "get",
               "id" => b_exec
             })

    assert msg =~ "not found"

    assert {:ok, %{executions: listed}} =
             Emissary.MCP.ToolRegistry.call_external("record", focused, %{"action" => "list"})

    refute Enum.any?(listed, &(&1.id == b_exec))

    # and so is B's storage: a URI is rooted in the focused athanor, never another
    assert {:error, "File not found" <> _} =
             Emissary.MCP.Tools.RecordsProvider.read(focused, "arca://files/data/secret.txt")

    assert {:ok, %{content: content}} =
             Emissary.MCP.Tools.RecordsProvider.read(b_ctx, "arca://files/data/secret.txt")

    assert Base.decode64!(content) == "b's bytes"
  end

  test "resolve_into gives an admin the capability, an :athanor scope, and their own athanor",
       %{ops: ops} do
    home = Athanors.home!()
    {:ok, _} = Members.ensure(ops, scope: "athanor", athanor_id: home.id)

    resolved =
      Sanctum.Tenancy.resolve_into(
        %Context{user_id: ops, athanor_id: nil, permissions: MapSet.new()},
        force: true
      )

    assert resolved.platform_admin
    assert resolved.scope == :athanor
    assert resolved.athanor_id == home.id
  end

  test "revalidate keeps a granted athanor and re-derives the capability", %{
    a: a,
    alice: alice,
    ctx: ctx
  } do
    c = ctx.(alice, a.id, true)
    out = Sanctum.Tenancy.revalidate(c)
    assert out.athanor_id == a.id
    refute out.platform_admin

    :ok = Members.remove_member(a, user_id: alice)
    out = Sanctum.Tenancy.revalidate(c)
    assert out.athanor_id == nil
  end
end
