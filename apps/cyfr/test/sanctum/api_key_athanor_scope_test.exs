# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ApiKeyAthanorScopeTest do
  @moduledoc """
  An API key is a credential of the one athanor it was minted in: it
  lists, focuses, revalidates into and reads that athanor alone, whatever
  other seats its creator holds, and its focus there is the key's, so its
  creator leaving the group does not take the athanor from it.
  """
  use ExUnit.Case, async: false

  alias Sanctum.{Caller, Context, Gate, TestContext}
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Prima.Test.RateLimiter.reset!()
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)

    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|keyscope-#{n}",
        provider: "github",
        email: "keyscope#{n}@example.com",
        verified: true
      })

    {:ok, a} = Athanors.create_group(user.id, "Key home #{n}")
    {:ok, b} = Athanors.create_group(user.id, "Other group #{n}")

    built =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        athanor_id: a.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = TestContext.create_session(built)
    {:ok, session_ctx} = Caller.establish(session.token, focus: a.id, task_supervisor: nil)

    name = "scope-key-#{n}"
    opts = %{name: name}

    issuing =
      TestContext.confirmed(session_ctx, :credential_issuance, %{
        operation: "key.create",
        arguments: opts,
        resource: name
      })

    {:ok, %{api_key: raw}} = Sanctum.ApiKey.create(issuing, opts)
    {:ok, key_ctx} = Caller.establish({:api_key, raw})

    {:ok, user: user, a: a, b: b, raw: raw, key_ctx: key_ctx, session_ctx: session_ctx}
  end

  test "a key minted in A neither lists, focuses nor reads B", %{
    a: a,
    b: b,
    raw: raw,
    key_ctx: key_ctx
  } do
    assert key_ctx.auth_method == :api_key
    assert key_ctx.athanor_id == a.id

    assert {:ok, %{athanors: athanors, count: 1}} =
             Gate.call_external("athanor", key_ctx, %{"action" => "list"})

    assert Enum.map(athanors, & &1.id) == [a.id]
    assert Enum.map(Sanctum.Tenancy.list_athanors(key_ctx), & &1.id) == [a.id]

    assert {:error, _} =
             Gate.call_external("member", key_ctx, %{"action" => "list", "athanor" => b.id})

    assert {:error, _} =
             Gate.call_external("athanor", key_ctx, %{"action" => "get", "athanor" => b.id})

    # The one tenancy refusal, the same as for an athanor that does not exist.
    assert Context.focus(key_ctx, b.id) == {:error, :not_found}
    assert Context.focus(key_ctx, b) == {:error, :not_found}
    assert Context.refocus(key_ctx, b.id) == {:error, :not_found}
    assert Context.focus(key_ctx, Prima.UUID7.generate_id("ath")) == {:error, :not_found}
    # A key's context is its row's athanor whatever focus is asked for.
    assert {:ok, %{athanor_id: athanor_id}} = Caller.establish({:api_key, raw}, focus: b.id)
    assert athanor_id == a.id
  end

  test "the key works in its own athanor", %{a: a, key_ctx: key_ctx} do
    assert {:ok, focused} = Context.focus(key_ctx, a.id)
    assert focused.athanor_id == a.id
    assert focused.credential_binding.focus_basis == :key

    assert {:ok, %{id: id}} = Gate.call_external("athanor", key_ctx, %{"action" => "get"})
    assert id == a.id

    assert {:ok, %{athanor: ^id, members: [_]}} =
             Gate.call_external("member", key_ctx, %{"action" => "list"})

    # Its own athanor's answer is filed whole in its log.
    assert {:ok, %{logs: rows}} =
             Gate.call_external("mcp_log", key_ctx, %{"action" => "list", "tool" => "athanor"})

    assert [%{status: "success", output: %{"id" => ^id}}] =
             Enum.filter(rows, &(&1.action == "get"))
  end

  test "a tincture the key invokes runs as the key, in the key's athanor alone", %{
    a: a,
    b: b,
    key_ctx: key_ctx,
    session_ctx: session_ctx
  } do
    tincture = %{publisher: "local", name: "key-scope-probe"}
    run_ctx = Sanctum.build_tincture_context(key_ctx, tincture)

    assert run_ctx.auth_method == :tincture
    assert run_ctx.user_id == key_ctx.user_id
    assert run_ctx.athanor_id == a.id
    assert run_ctx.api_key_id == key_ctx.api_key_id
    assert run_ctx.credential_binding == key_ctx.credential_binding
    assert Context.key_bound?(run_ctx)

    assert Enum.map(Sanctum.Tenancy.list_athanors(run_ctx), & &1.id) == [a.id]
    assert Context.focus(run_ctx, b.id) == {:error, :not_found}
    assert {:ok, %{athanor_id: athanor_id}} = Context.focus(run_ctx, a.id)
    assert athanor_id == a.id

    # A person's own invocation still follows their seats, and carries no
    # sign-in's binding into the run.
    person_run = Sanctum.build_tincture_context(session_ctx, tincture)
    refute Context.key_bound?(person_run)
    assert is_nil(person_run.api_key_id)
    assert is_nil(person_run.credential_binding)
    assert b.id in Enum.map(Sanctum.Tenancy.list_athanors(person_run), & &1.id)
  end

  test "the key keeps its athanor after its creator leaves it, and gains no other", %{
    user: user,
    a: a,
    b: b,
    raw: raw
  } do
    other = "github|https://github.com|stays-#{System.unique_integer([:positive])}"
    {:ok, _} = Members.ensure(other, scope: "athanor", athanor_id: a.id)
    :ok = Members.remove_member(a, user_id: user.id)
    assert {:ok, %{status: "active"}} = Athanors.get(a.id)

    {:ok, key_ctx} = Caller.establish({:api_key, raw})
    assert Enum.map(Sanctum.Tenancy.list_athanors(key_ctx), & &1.id) == [a.id]
    assert {:ok, %{athanor_id: athanor_id}} = Context.focus(key_ctx, a.id)
    assert athanor_id == a.id
    assert Context.focus(key_ctx, b.id) == {:error, :not_found}
  end

  test "revalidation keeps the key in its athanor, never its creator's other seat", %{
    user: user,
    a: a,
    raw: raw
  } do
    {:ok, key_ctx} = Caller.establish({:api_key, raw})
    assert {:ok, %{athanor_id: athanor_id}} = Sanctum.Tenancy.revalidate(key_ctx)
    assert athanor_id == a.id

    other = "github|https://github.com|stays-#{System.unique_integer([:positive])}"
    {:ok, _} = Members.ensure(other, scope: "athanor", athanor_id: a.id)
    :ok = Members.remove_member(a, user_id: user.id)

    {:ok, key_ctx} = Caller.establish({:api_key, raw})
    assert {:ok, revalidated} = Sanctum.Tenancy.revalidate(key_ctx)
    assert revalidated.athanor_id == a.id
    assert Context.key_bound?(revalidated)
    refute revalidated.platform_admin

    {:ok, _} = Athanors.archive(a)
    assert {:ok, %{athanor_id: nil}} = Sanctum.Tenancy.revalidate(key_ctx)
  end

  test "an archived key athanor is refused as archived, and lists nothing", %{
    a: a,
    key_ctx: key_ctx
  } do
    {:ok, _} = Athanors.archive(a)
    assert Context.focus(key_ctx, a.id) == {:error, :archived}
    assert Sanctum.Tenancy.list_athanors(key_ctx) == []
  end
end
