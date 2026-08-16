# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ConversationStorageTest do
  use ExUnit.Case, async: false

  alias Arca.ConversationStorage, as: Conversations
  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, ctx: user_ctx("local|idp|alice", "ath_a"), bob: user_ctx("local|idp|bob", "ath_a")}
  end

  defp user_ctx(user_id, athanor_id) do
    Context.build(
      user_id: user_id,
      provider: "oidc",
      athanor_id: athanor_id,
      permissions: [:*],
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  test "a conversation belongs to the athanor; another athanor cannot see it", %{ctx: ctx} do
    {:ok, conv} = Conversations.create(ctx)
    assert conv.athanor_id == "ath_a"
    assert conv.created_by == ctx.user_id
    assert [%{id: id}] = Conversations.list(ctx)
    assert id == conv.id

    other = user_ctx("local|idp|carol", "ath_b")
    assert Conversations.list(other) == []
    assert {:error, :not_found} = Conversations.get(other, conv.id)

    assert {:error, :not_found} =
             Conversations.append(other, conv.id, %{author: "x", content: "hi"})
  end

  test "an athanor-less context cannot read", %{ctx: ctx} do
    assert_raise ArgumentError, ~r/athanor_id is required/, fn ->
      Conversations.list(%{ctx | athanor_id: nil})
    end
  end

  test "messages append in seq order and the first user text titles the thread", %{
    ctx: ctx,
    bob: bob
  } do
    {:ok, conv} = Conversations.create(ctx)
    assert conv.title == "New conversation"

    {:ok, m1} =
      Conversations.append(ctx, conv.id, %{author: ctx.user_id, content: "Plan my week\nplease"})

    {:ok, m2} = Conversations.append(bob, conv.id, %{author: "aqua", content: "Sure."})
    {:ok, m3} = Conversations.append(bob, conv.id, %{author: bob.user_id, content: "Thanks"})

    assert [m1.seq, m2.seq, m3.seq] == [1, 2, 3]
    assert Enum.map(Conversations.messages(ctx, conv.id), & &1.id) == [m1.id, m2.id, m3.id]

    {:ok, conv} = Conversations.get(ctx, conv.id)
    assert conv.title == "Plan my week"
    assert conv.last_message_at
  end

  test "payload and history round-trip as JSON", %{ctx: ctx} do
    {:ok, conv} = Conversations.create(ctx)

    {:ok, msg} =
      Conversations.append(ctx, conv.id, %{
        author: "aqua",
        payload: %{"intent" => %{"title" => "t"}}
      })

    assert Conversations.payload(msg) == %{"intent" => %{"title" => "t"}}

    {:ok, conv} =
      Conversations.update(ctx, conv.id, %{history: [%{"role" => "user", "content" => "hi"}]})

    assert Conversations.history(conv) == [%{"role" => "user", "content" => "hi"}]
  end

  test "an approval is decided once — the second click sees already_resolved", %{
    ctx: ctx,
    bob: bob
  } do
    {:ok, conv} = Conversations.create(ctx)

    {:ok, apr} =
      Conversations.append(ctx, conv.id, %{
        author: "aqua",
        kind: "approval",
        content: "Send it",
        status: "pending"
      })

    assert [%{id: id}] = Conversations.pending_approvals(ctx, conv.id)
    assert id == apr.id

    assert {:ok, running} = Conversations.resolve_approval(ctx, apr.id, "pending", "running")
    assert running.status == "running"
    assert running.resolved_by == ctx.user_id
    assert running.resolved_at == nil

    assert {:error, :already_resolved} =
             Conversations.resolve_approval(bob, apr.id, "pending", "declined")

    assert {:ok, done} =
             Conversations.resolve_approval(ctx, apr.id, "running", "approved", %{
               resolution: %{"summary" => "ok"}
             })

    assert done.status == "approved"
    assert done.resolved_at
    assert Conversations.resolution(done) == %{"summary" => "ok"}
    assert Conversations.pending_approvals(ctx, conv.id) == []

    assert {:error, :not_found} =
             Conversations.resolve_approval(ctx, "msg_nope", "pending", "running")
  end

  test "delete removes the messages too", %{ctx: ctx} do
    {:ok, conv} = Conversations.create(ctx)
    {:ok, _} = Conversations.append(ctx, conv.id, %{author: "aqua", content: "x"})
    :ok = Conversations.delete(ctx, conv.id)
    assert Conversations.messages(ctx, conv.id) == []
    assert {:error, :not_found} = Conversations.get(ctx, conv.id)
  end

  test "retention drops stale idle conversations and keeps a running one", %{ctx: ctx} do
    {:ok, stale} = Conversations.create(ctx)
    {:ok, running} = Conversations.create(ctx)
    {:ok, fresh} = Conversations.create(ctx)
    {:ok, _} = Conversations.append(ctx, fresh.id, %{author: "aqua", content: "recent"})

    old = DateTime.add(DateTime.utc_now(), -400 * 86_400, :second)
    {:ok, _} = Conversations.update(ctx, stale.id, %{last_message_at: old})

    {:ok, _} =
      Conversations.update(ctx, running.id, %{last_message_at: old, execution_id: "exec_1"})

    cutoff = DateTime.add(DateTime.utc_now(), -365 * 86_400, :second)
    assert {1, nil} = Conversations.delete_before(cutoff, athanor_id: "ath_a")

    ids = Conversations.list(ctx) |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == Enum.sort([running.id, fresh.id])
    assert [running.id] == Enum.map(Conversations.with_running_turn(), & &1.id)
    assert "ath_a" in Conversations.distinct_athanors()
  end
end
