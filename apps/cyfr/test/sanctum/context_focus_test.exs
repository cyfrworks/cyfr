# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ContextFocusTest do
  @moduledoc """
  Focus narrows everyone, admins included: a request context works inside
  one athanor, and only the one its person owns. Being a platform admin is
  a capability over the instance that admits the platform-scope
  operations — never another person's athanor, and never a wider tenant
  scope.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.Tenancy.Athanors

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    alice = "github|https://github.com|alice-#{System.unique_integer([:positive])}"
    a = own!(alice, "A")
    b = own!("github|https://github.com|someone", "B")

    # The operator is a person with their own athanor and the mark.
    {:ok, %{id: ops}} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|ops-#{System.unique_integer([:positive])}",
        provider: "github"
      })

    {:ok, _} = Sanctum.TestContext.ensure_platform(ops)

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

  # The athanor `user_id` owns, as their admission mints it.
  defp own!(user_id, name) do
    name = "#{name} #{System.unique_integer([:positive])}"
    {:ok, slugs} = Athanors.person_slugs(nil, name)

    {:ok, athanor} =
      Athanors.create_personal(%{name: name, owner_user_id: user_id, created_by: user_id}, slugs)

    athanor
  end

  test "a person focuses their own athanor; anyone else's is refused", %{
    a: a,
    b: b,
    alice: alice,
    ctx: ctx
  } do
    c = ctx.(alice, nil, false)
    assert {:ok, focused} = Context.focus(c, a.id)
    assert focused.athanor_id == a.id
    assert focused.scope == :athanor
    assert {:error, :not_found} = Context.focus(c, b)
    assert {:error, :not_found} = Context.focus(c, "ath_nope")
  end

  test "a caller who is not the owner is answered alike for an open, an archived and a missing athanor; the owner hears archived",
       %{a: a, b: b, alice: alice, ops: ops, ctx: ctx} do
    archived = Sanctum.TestContext.archive!(a.id)
    missing = Prima.UUID7.generate_id("ath")

    # Neither a stranger nor an operator learns which of the three it is.
    for caller <- [
          ctx.("github|https://github.com|stranger", nil, false),
          ctx.(ops, nil, true)
        ] do
      answers = for id <- [b.id, archived.id, missing], do: Context.focus(caller, id)
      assert answers == List.duplicate({:error, :not_found}, 3)
      assert Context.refocus(caller, archived.id) == {:error, :not_found}
    end

    # The owner is told the truth.
    assert {:error, :archived} = Context.focus(ctx.(alice, nil, false), archived.id)
  end

  test "an archived athanor cannot be focused", %{a: a, alice: alice, ctx: ctx} do
    archived = Sanctum.TestContext.archive!(a.id)
    assert {:error, :archived} = Context.focus(ctx.(alice, nil, false), archived)
  end

  test "a stale copy of the row is read for its id alone: focus rereads the standing",
       %{a: a, alice: alice, ctx: ctx} do
    {:ok, before_archive} = Athanors.get(a.id)
    Sanctum.TestContext.archive!(a.id)

    # The copy still says active; the row it names does not.
    assert before_archive.status == "active"
    assert {:error, :archived} = Context.focus(ctx.(alice, nil, false), before_archive)

    # A map that only names the id is as good as the id, and a forged
    # status on it decides nothing.
    assert {:error, :archived} =
             Context.focus(ctx.(alice, nil, false), %{id: a.id, status: "active"})
  end

  test "a store that cannot answer is unavailable, never an absence or a refusal",
       %{a: a, b: b, alice: alice, ops: ops, ctx: ctx} do
    c = ctx.(alice, nil, false)
    Sanctum.TestContext.archive!(b.id)

    Arca.Repo.query!("ALTER TABLE athanors RENAME TO athanors_unavailable")
    assert {:error, :unavailable} = Context.focus(c, a.id)
    assert {:error, :unavailable} = Context.focus(c, a)

    # An unreadable owner is not another one, for an archived athanor the
    # caller does not own too: the outage is never folded into the
    # outsider's refusal.
    assert {:error, :unavailable} = Context.focus(c, b.id)
    assert {:error, :unavailable} = Context.focus(ctx.(ops, nil, true), b.id)

    sys = Sanctum.Context.internal(user_id: "_test", athanor_id: a.id, scope: :athanor)
    assert {:error, :unavailable} = Context.refocus(sys, a.id)
  end

  test "refocus is focus for a person, and an archive-checked crossing for the system plane",
       %{a: a, b: b, alice: alice, ctx: ctx} do
    # A person's refocus IS focus: the owner in, anyone else out.
    c = ctx.(alice, nil, false)
    assert {:ok, %{athanor_id: id}} = Context.refocus(c, a.id)
    assert id == a.id
    assert {:error, :not_found} = Context.refocus(c, b.id)

    # The system plane crosses tenants by design (recovery resolving a
    # stored agent has no person to speak as) — but a closed furnace stays
    # closed to it too.
    sys = Sanctum.Context.internal(user_id: "_test", athanor_id: a.id, scope: :athanor)
    assert {:ok, %{athanor_id: bid, scope: :athanor} = crossed} = Context.refocus(sys, b.id)
    assert bid == b.id

    # The actor it projects keeps the system provenance and still reads one
    # athanor: the two authorities Arca decides on are separate, and a
    # crossing narrows the scope without giving up the system write.
    assert Context.actor(crossed).system
    assert Context.actor(crossed).scope == :athanor

    Sanctum.TestContext.archive!(b.id)
    assert {:error, :archived} = Context.refocus(sys, b.id)
    assert {:error, :not_found} = Context.refocus(sys, "ath_nope")

    # No athanor at all — an id read off a record that had none — is the
    # spec's refusal, not a clause error.
    assert {:error, :not_found} = Context.refocus(sys, nil)
    assert {:error, :not_found} = Context.refocus(c, nil)
  end

  test "a platform administrator focuses no athanor but their own",
       %{a: a, b: b, ops: ops, ctx: ctx} do
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

    # Two other people's own athanors: the capability opens neither, so
    # focus refuses the operator exactly as it refuses anyone.
    for athanor <- [a, b] do
      assert {:error, :not_found} = Context.focus(admin, athanor)
      assert {:error, :not_found} = Context.focus(admin, athanor.id)
      assert {:error, :not_found} = Context.refocus(admin, athanor.id)
    end

    # Their own athanor they focus as its person.
    own = Sanctum.Test.People.athanor!(ops)
    assert {:ok, %{athanor_id: own_id}} = Context.focus(admin, own)
    assert own_id == own.id

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
    assert {:error, :not_found} = Context.focus(platform, b)
    refute_received {:audit, _}
  end

  test "a person focused on A cannot read B's records, operator or not — no scope bypass",
       %{b: b, ops: ops, ctx: ctx} do
    # The operator focuses their own athanor A: a person like any other,
    # whose capability widens nothing.
    a = Sanctum.Test.People.athanor!(ops)
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

  test "a person focused on A cannot reach B's execution or files through the tools either, operator or not",
       %{b: b, ops: ops, ctx: ctx} do
    a = Sanctum.Test.People.athanor!(ops)
    {:ok, focused} = Context.focus(ctx.(ops, nil, true), a)
    b_exec = "exec_b_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Arca.Test.Writers.record_start(%{
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
             Sanctum.Gate.call_external("record", focused, %{
               "action" => "get",
               "id" => b_exec
             })

    assert err_msg(msg) =~ "not found"

    assert {:ok, %{executions: listed}} =
             Sanctum.Gate.call_external("record", focused, %{"action" => "list"})

    refute Enum.any?(listed, &(&1.id == b_exec))

    # and so is B's storage: a URI is rooted in the focused athanor, never another
    read = %{"action" => "read", "uri" => "arca://files/data/secret.txt"}

    assert {:error, {:not_found, "File", _}} =
             Sanctum.Gate.call_external("resource", focused, read)

    assert {:ok, %{content: content}} = Sanctum.Gate.call_external("resource", b_ctx, read)

    assert Base.decode64!(content) == "b's bytes"
  end

  test "resolve_status gives an admin the capability, an :athanor scope, and their own athanor",
       %{ops: ops} do
    athanor = Sanctum.Test.People.athanor!(ops)

    {:ok, resolved} =
      Sanctum.Tenancy.resolve_status(
        %Context{user_id: ops, athanor_id: nil, permissions: MapSet.new()},
        force: true
      )

    assert resolved.platform_admin
    assert resolved.scope == :athanor
    assert resolved.athanor_id == athanor.id
  end

  test "revalidate keeps the person's own athanor and re-derives the capability", %{
    a: a,
    alice: alice,
    ctx: ctx
  } do
    c = ctx.(alice, a.id, true)
    {:ok, out} = Sanctum.Tenancy.revalidate(c)
    assert out.athanor_id == a.id
    refute out.platform_admin
  end

  # Providers answer typed reasons where the class is clear; the shared
  # renderer is the one spelling of every sentence, so assert through it.
  # Plain strings pass through unchanged.
  defp err_msg(reason) do
    Sanctum.Refusals.render(reason) ||
      flunk("unrenderable refusal: #{inspect(reason)}")
  end
end
