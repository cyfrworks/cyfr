# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.StandingWatchTest do
  @moduledoc """
  An established-caller memo is a cached authorization decision held in
  each member's own table. Dropping it must reach every member, not only
  the one that revoked — and a delivery that never arrives must not let a
  revoked authority outlive the memo's TTL.

  One VM plays both members: the announcement's trip onto the bus is one
  case, and what a member that hears it does is the other.
  """
  use ExUnit.Case, async: false

  import Cyfr.Test.Wait

  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Users}

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    original = Application.get_env(:sanctum, :caller_memo_ttl_ms)
    Application.put_env(:sanctum, :caller_memo_ttl_ms, 60_000)

    on_exit(fn ->
      Arca.Cache.delete_match({:established, :_, :_, :_})

      if original,
        do: Application.put_env(:sanctum, :caller_memo_ttl_ms, original),
        else: Application.delete_env(:sanctum, :caller_memo_ttl_ms)
    end)

    n = System.unique_integer([:positive])

    {:ok, owner} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|standing-#{n}",
        provider: "github",
        email: "standing#{n}@example.com",
        verified: true
      })

    {:ok, group} = Athanors.create_group(owner.id, "Standing #{n}")

    {:ok, session} =
      Sanctum.TestContext.create_session(%{
        member_ctx(group.id, owner.id)
        | provider: "github",
          email: owner.email
      })

    {:ok, group: group, session: session, hash: Sanctum.Session.token_hash(session.token)}
  end

  test "an archive announces the row key on the bus, so a peer hears it", %{
    group: group,
    session: session,
    hash: hash
  } do
    assert {:ok, %Context{}} = Sanctum.Caller.establish(session.token)

    Cyfr.Bus.subscribe_global(Cyfr.Bus.caller_invalidated_global())

    assert {:ok, %{status: "archived"}} = Athanors.archive(group)

    assert_receive %Cyfr.Bus.CallerInvalidated{session_key: ^hash}, 5_000
  end

  test "an athanor archived on another member refuses a caller this one had cached", %{
    group: group,
    session: session,
    hash: hash
  } do
    assert {:ok, %Context{athanor_id: cached} = ctx} = Sanctum.Caller.establish(session.token)
    assert cached == group.id

    # Member A archives. This VM is also member A, so it drops its own
    # copy; putting it back is what member B's table still holds, having
    # heard nothing yet.
    assert {:ok, %{status: "archived"}} = Athanors.archive(group)
    Arca.Cache.put(Arca.Cache.Keys.established(hash, :console, nil), ctx, 60_000)

    assert {:ok, %Context{athanor_id: ^cached}} = Sanctum.Caller.establish(session.token),
           "the memo under test is not the one a cached caller is served from"

    # The announcement arrives.
    Cyfr.Bus.broadcast_global(
      Cyfr.Bus.caller_invalidated_global(),
      Cyfr.Bus.CallerInvalidated.new(hash)
    )

    assert :ok =
             wait_until(
               fn -> Arca.Cache.match(Arca.Cache.Keys.match_established(hash)) == [] end,
               5_000
             )

    refute match?({:ok, %Context{athanor_id: ^cached}}, Sanctum.Caller.establish(session.token))
  end

  defp member_ctx(athanor_id, user_id) do
    Context.build(
      user_id: user_id,
      athanor_id: athanor_id,
      permissions: [:*],
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end
end
