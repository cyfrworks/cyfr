# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ConversationStorageTest.FailingDeleteAdapter do
  @moduledoc false
  defdelegate get(ctx, path), to: Arca.Adapters.Local
  defdelegate put(ctx, path, content), to: Arca.Adapters.Local
  defdelegate append(ctx, path, content), to: Arca.Adapters.Local
  defdelegate delete(ctx, path), to: Arca.Adapters.Local
  defdelegate list_typed(ctx, path), to: Arca.Adapters.Local
  defdelegate exists?(ctx, path), to: Arca.Adapters.Local
  defdelegate list_recursive(ctx, path), to: Arca.Adapters.Local
  defdelegate usage(ctx, path), to: Arca.Adapters.Local
  defdelegate serve_to_conn(conn, ctx, path, opts), to: Arca.Adapters.Local

  # A conversation's whole blob tree refuses to delete.
  def delete_tree(_ctx, ["conversations", _id]), do: {:error, :eacces}
  defdelegate delete_tree(ctx, path), to: Arca.Adapters.Local
end

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

  test "blob_root/1 spells a real tenant root" do
    # The module owns the "conversations" literal (the layout table's
    # roster pattern: the literal lives at its single consumer, with this
    # membership witness) — a renamed row cannot silently orphan blobs.
    assert hd(Conversations.blob_root("conv_x")) in Arca.Storage.tenant_roots()
  end

  test "delete removes the messages and the attachment blobs too", %{ctx: ctx} do
    {:ok, conv} = Conversations.create(ctx)
    {:ok, msg} = Conversations.append(ctx, conv.id, %{author: "aqua", content: "x"})
    blob = Conversations.blob_root(conv.id) ++ [msg.id, "0-a.txt"]
    :ok = Arca.put(ctx, blob, "bytes")

    :ok = Conversations.delete(ctx, conv.id)
    assert Conversations.messages(ctx, conv.id) == []
    assert {:error, :not_found} = Conversations.get(ctx, conv.id)
    refute Arca.exists?(ctx, blob)
  end

  test "delete goes bytes-first: a failed blob delete keeps the rows", %{ctx: ctx} do
    {:ok, conv} = Conversations.create(ctx)
    {:ok, msg} = Conversations.append(ctx, conv.id, %{author: "aqua", content: "x"})
    blob = Conversations.blob_root(conv.id) ++ [msg.id, "0-a.txt"]
    :ok = Arca.put(ctx, blob, "bytes")

    prev = Application.get_env(:cyfr, :storage_adapter)

    Application.put_env(
      :cyfr,
      :storage_adapter,
      Arca.ConversationStorageTest.FailingDeleteAdapter
    )

    on_exit(fn ->
      if prev,
        do: Application.put_env(:cyfr, :storage_adapter, prev),
        else: Application.delete_env(:cyfr, :storage_adapter)
    end)

    # The DB never claims a deletion the tree didn't make.
    assert {:error, {:storage_delete_failed, :eacces}} = Conversations.delete(ctx, conv.id)
    assert {:ok, _} = Conversations.get(ctx, conv.id)
    assert [_] = Conversations.messages(ctx, conv.id)

    # Healed adapter: the retry completes rows and bytes together.
    Application.put_env(:cyfr, :storage_adapter, prev || Arca.Adapters.Local)
    assert :ok = Conversations.delete(ctx, conv.id)
    refute Arca.exists?(ctx, blob)
  end

  test "sweep_orphaned_blobs/1 reclaims rowless dirs and keeps live ones", %{ctx: ctx} do
    {:ok, conv} = Conversations.create(ctx)
    live = Conversations.blob_root(conv.id) ++ ["msg", "keep.txt"]
    :ok = Arca.put(ctx, live, "keep")

    orphan = Conversations.blob_root("conv_orphan") ++ ["msg", "gone.txt"]
    :ok = Arca.put(ctx, orphan, "gone")

    # The suite's storage tree is shared, so other tests' leavings may be
    # reclaimed alongside — pin the fates, not the count.
    assert {:ok, reclaimed} = Conversations.sweep_orphaned_blobs(ctx)
    assert reclaimed >= 1
    assert Arca.exists?(ctx, live)
    refute Arca.exists?(ctx, orphan)
  end

  test "messages/3 windows the thread by seq, and the turn cursor round-trips", %{ctx: ctx} do
    {:ok, conv} = Conversations.create(ctx)

    for n <- 1..4,
        do: {:ok, _} = Conversations.append(ctx, conv.id, %{author: "u", content: "m#{n}"})

    seqs = fn opts -> Conversations.messages(ctx, conv.id, opts) |> Enum.map(& &1.seq) end
    assert seqs.([]) == [1, 2, 3, 4]
    assert seqs.(after_seq: 1) == [2, 3, 4]
    assert seqs.(after_seq: 1, upto_seq: 3) == [2, 3]
    assert seqs.(upto_seq: 2) == [1, 2]

    assert {:ok, %{turn_seq: 0, orchestrator: nil}} = Conversations.get(ctx, conv.id)
    {:ok, updated} = Conversations.update(ctx, conv.id, %{turn_seq: 3, orchestrator: "aqua"})
    assert updated.turn_seq == 3 and updated.orchestrator == "aqua"
  end

  test "the title drops a leading @mention but the row keeps the text as typed", %{ctx: ctx} do
    {:ok, conv} = Conversations.create(ctx)

    {:ok, msg} =
      Conversations.append(ctx, conv.id, %{author: "u", content: "@aqua what's the plan?"})

    assert msg.content == "@aqua what's the plan?"
    assert {:ok, %{title: "what's the plan?"}} = Conversations.get(ctx, conv.id)
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

    # a blob under the stale conversation goes with it
    :ok = Arca.put(ctx, Conversations.blob_root(stale.id) ++ ["msg_1", "note.txt"], "bytes")

    cutoff = DateTime.add(DateTime.utc_now(), -365 * 86_400, :second)
    assert {:ok, 1} = Conversations.delete_before(ctx, cutoff)
    refute Arca.exists?(ctx, Conversations.blob_root(stale.id) ++ ["msg_1", "note.txt"])

    ids = Conversations.list(ctx) |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == Enum.sort([running.id, fresh.id])
    assert [running.id] == Enum.map(Conversations.with_running_turn(), & &1.id)
    assert "ath_a" in Conversations.distinct_athanors()
  end
end
