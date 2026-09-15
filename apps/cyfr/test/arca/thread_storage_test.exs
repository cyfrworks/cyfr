# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ThreadStorageTest.FailingDeleteAdapter do
  @moduledoc false
  use Arca.Storage.TestDouble

  # A thread's whole blob tree refuses to delete.
  def delete_tree(_ctx, ["threads", _id]), do: {:error, :eacces}
  def delete_tree(ctx, path), do: Arca.Adapters.Local.delete_tree(ctx, path)
end

defmodule Arca.ThreadStorageTest do
  use ExUnit.Case, async: false

  alias Arca.ThreadStorage, as: Threads
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

  test "a thread belongs to the athanor; another athanor cannot see it", %{ctx: ctx} do
    {:ok, thread} = Threads.create(ctx)
    assert thread.athanor_id == "ath_a"
    assert thread.created_by == ctx.user_id
    assert [%{id: id}] = Threads.list(ctx)
    assert id == thread.id

    other = user_ctx("local|idp|carol", "ath_b")
    assert Threads.list(other) == []
    assert {:error, :not_found} = Threads.get(other, thread.id)

    assert {:error, :not_found} =
             Threads.append(other, thread.id, %{author: "x", content: "hi"})
  end

  test "an athanor-less context cannot read", %{ctx: ctx} do
    assert_raise ArgumentError, ~r/athanor_id is required/, fn ->
      Threads.list(%{ctx | athanor_id: nil})
    end
  end

  test "messages append in seq order and the first user text titles the thread", %{
    ctx: ctx,
    bob: bob
  } do
    {:ok, thread} = Threads.create(ctx)
    assert thread.title == "New thread"

    {:ok, m1} =
      Threads.append(ctx, thread.id, %{author: ctx.user_id, content: "Plan my week\nplease"})

    {:ok, m2} = Threads.append(bob, thread.id, %{author: "aqua", content: "Sure."})
    {:ok, m3} = Threads.append(bob, thread.id, %{author: bob.user_id, content: "Thanks"})

    assert [m1.seq, m2.seq, m3.seq] == [1, 2, 3]
    assert Enum.map(Threads.messages(ctx, thread.id), & &1.id) == [m1.id, m2.id, m3.id]

    {:ok, thread} = Threads.get(ctx, thread.id)
    assert thread.title == "Plan my week"
    assert thread.last_message_at
  end

  test "a payload round-trips as JSON", %{ctx: ctx} do
    {:ok, thread} = Threads.create(ctx)

    {:ok, msg} =
      Threads.append(ctx, thread.id, %{
        author: "aqua",
        payload: %{"intent" => %{"title" => "t"}}
      })

    assert Threads.payload(msg) == %{"intent" => %{"title" => "t"}}
  end

  test "an approval is decided once — the second click sees already_resolved", %{
    ctx: ctx,
    bob: bob
  } do
    {:ok, thread} = Threads.create(ctx)

    {:ok, apr} =
      Threads.append(ctx, thread.id, %{
        author: "aqua",
        kind: "approval",
        content: "Send it",
        status: "pending"
      })

    assert [%{id: id}] = Threads.pending_approvals(ctx, thread.id)
    assert id == apr.id

    assert {:ok, running} = Threads.resolve_approval(ctx, apr.id, "pending", "running")
    assert running.status == "running"
    assert running.resolved_by == ctx.user_id
    assert running.resolved_at == nil

    assert {:error, :already_resolved} =
             Threads.resolve_approval(bob, apr.id, "pending", "declined")

    assert {:ok, done} =
             Threads.resolve_approval(ctx, apr.id, "running", "approved", %{
               resolution: %{"summary" => "ok"}
             })

    assert done.status == "approved"
    assert done.resolved_at
    assert Threads.resolution(done) == %{"summary" => "ok"}
    assert Threads.pending_approvals(ctx, thread.id) == []

    assert {:error, :not_found} =
             Threads.resolve_approval(ctx, "msg_nope", "pending", "running")
  end

  test "blob_root/1 spells a real tenant root" do
    # The module owns the "threads" literal (the layout table's
    # roster pattern: the literal lives at its single consumer, with this
    # membership witness) — a renamed row cannot silently orphan blobs.
    assert hd(Threads.blob_root("thread_x")) in Arca.Storage.tenant_roots()
  end

  test "delete removes the messages and the attachment blobs too", %{ctx: ctx} do
    {:ok, thread} = Threads.create(ctx)
    {:ok, msg} = Threads.append(ctx, thread.id, %{author: "aqua", content: "x"})
    blob = Threads.blob_root(thread.id) ++ [msg.id, "0-a.txt"]
    :ok = Arca.put(ctx, blob, "bytes")

    :ok = Threads.delete(ctx, thread.id)
    assert Threads.messages(ctx, thread.id) == []
    assert {:error, :not_found} = Threads.get(ctx, thread.id)
    refute Arca.exists?(ctx, blob)
  end

  test "delete goes bytes-first: a failed blob delete keeps the rows", %{ctx: ctx} do
    {:ok, thread} = Threads.create(ctx)
    {:ok, msg} = Threads.append(ctx, thread.id, %{author: "aqua", content: "x"})
    blob = Threads.blob_root(thread.id) ++ [msg.id, "0-a.txt"]
    :ok = Arca.put(ctx, blob, "bytes")

    prev = Application.get_env(:cyfr, :storage_adapter)

    Application.put_env(
      :cyfr,
      :storage_adapter,
      Arca.ThreadStorageTest.FailingDeleteAdapter
    )

    on_exit(fn ->
      if prev,
        do: Application.put_env(:cyfr, :storage_adapter, prev),
        else: Application.delete_env(:cyfr, :storage_adapter)
    end)

    # The DB never claims a deletion the tree didn't make.
    assert {:error, {:storage_delete_failed, :eacces}} = Threads.delete(ctx, thread.id)
    assert {:ok, _} = Threads.get(ctx, thread.id)
    assert [_] = Threads.messages(ctx, thread.id)

    # Healed adapter: the retry completes rows and bytes together.
    Application.put_env(:cyfr, :storage_adapter, prev || Arca.Adapters.Local)
    assert :ok = Threads.delete(ctx, thread.id)
    refute Arca.exists?(ctx, blob)
  end

  test "sweep_orphaned_blobs/1 reclaims rowless dirs and keeps live ones", %{ctx: ctx} do
    {:ok, thread} = Threads.create(ctx)
    live = Threads.blob_root(thread.id) ++ ["msg", "keep.txt"]
    :ok = Arca.put(ctx, live, "keep")

    orphan = Threads.blob_root("thread_orphan") ++ ["msg", "gone.txt"]
    :ok = Arca.put(ctx, orphan, "gone")

    # The suite's storage tree is shared, so other tests' leavings may be
    # reclaimed alongside — pin the fates, not the count.
    assert {:ok, reclaimed} = Threads.sweep_orphaned_blobs(ctx)
    assert reclaimed >= 1
    assert Arca.exists?(ctx, live)
    refute Arca.exists?(ctx, orphan)
  end

  test "messages/3 windows the thread by seq, and the turn cursor round-trips", %{ctx: ctx} do
    {:ok, thread} = Threads.create(ctx)

    for n <- 1..4,
        do: {:ok, _} = Threads.append(ctx, thread.id, %{author: "u", content: "m#{n}"})

    seqs = fn opts -> Threads.messages(ctx, thread.id, opts) |> Enum.map(& &1.seq) end
    assert seqs.([]) == [1, 2, 3, 4]
    assert seqs.(after_seq: 1) == [2, 3, 4]
    assert seqs.(after_seq: 1, upto_seq: 3) == [2, 3]
    assert seqs.(upto_seq: 2) == [1, 2]

    assert {:ok, %{turn_seq: 0, orchestrator: nil}} = Threads.get(ctx, thread.id)
    {:ok, updated} = Threads.update(ctx, thread.id, %{turn_seq: 3, orchestrator: "aqua"})
    assert updated.turn_seq == 3 and updated.orchestrator == "aqua"
  end

  test "the reserved authors are the schema's, and neither titles a thread", %{ctx: ctx} do
    # Rows persist with these values, so the spelling is pinned as well as
    # the fact that every writer reads it from one place.
    assert Arca.Schemas.Message.agent_author() == "aqua"
    assert Arca.Schemas.Message.system_author() == "system"

    {:ok, thread} = Threads.create(ctx)

    for author <- [Arca.Schemas.Message.agent_author(), Arca.Schemas.Message.system_author()] do
      {:ok, _} =
        Threads.append(ctx, thread.id, %{author: author, kind: "text", content: "not a title"})
    end

    {:ok, still} = Threads.get(ctx, thread.id)
    refute still.title == "not a title"
  end

  test "the title drops a leading @mention but the row keeps the text as typed", %{ctx: ctx} do
    {:ok, thread} = Threads.create(ctx)

    {:ok, msg} =
      Threads.append(ctx, thread.id, %{author: "u", content: "@aqua what's the plan?"})

    assert msg.content == "@aqua what's the plan?"
    assert {:ok, %{title: "what's the plan?"}} = Threads.get(ctx, thread.id)
  end

  test "retention drops stale idle threads and keeps one holding an open turn", %{ctx: ctx} do
    {:ok, stale} = Threads.create(ctx)
    {:ok, running} = Threads.create(ctx)
    {:ok, fresh} = Threads.create(ctx)
    {:ok, _} = Threads.append(ctx, fresh.id, %{author: "aqua", content: "recent"})

    old = DateTime.add(DateTime.utc_now(), -400 * 86_400, :second)
    {:ok, _} = Threads.update(ctx, stale.id, %{last_message_at: old})

    {:ok, _} =
      Arca.TurnStorage.accept_message(ctx, running.id, %{
        message: %{author: ctx.user_id, content: "@aqua go"},
        turn: %{orchestrator: "aqua", requested_by: ctx.user_id}
      })

    {:ok, _} = Threads.update(ctx, running.id, %{last_message_at: old})

    # a blob under the stale thread goes with it
    :ok = Arca.put(ctx, Threads.blob_root(stale.id) ++ ["msg_1", "note.txt"], "bytes")

    cutoff = DateTime.add(DateTime.utc_now(), -365 * 86_400, :second)
    assert {:ok, 1} = Threads.delete_before(ctx, cutoff)
    refute Arca.exists?(ctx, Threads.blob_root(stale.id) ++ ["msg_1", "note.txt"])

    ids = Threads.list(ctx) |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == Enum.sort([running.id, fresh.id])
  end
end
