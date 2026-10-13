# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ThreadStorageTest.FailingDeleteAdapter do
  @moduledoc false
  use Arca.Storage.TestDouble

  # A thread's whole blob tree refuses to delete.
  def delete_tree(_ctx, ["threads", _id]), do: {:error, :eacces}

  def delete_tree(actor, path),
    do: Arca.Adapters.Local.delete_tree(actor, path)
end

defmodule Arca.ThreadStorageTest do
  use ExUnit.Case, async: false

  alias Arca.ThreadStorage, as: Threads
  alias Sanctum.Context

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    {:ok, ctx: user_actor("local|idp|alice", "ath_a"), bob: user_actor("local|idp|bob", "ath_a")}
  end

  defp user_actor(user_id, athanor_id) do
    Sanctum.Context.actor(
      Context.build(
        user_id: user_id,
        provider: "oidc",
        athanor_id: athanor_id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )
    )
  end

  test "a thread belongs to the athanor; another athanor cannot see it", %{ctx: ctx} do
    {:ok, thread} = Threads.create(ctx)
    assert thread.athanor_id == "ath_a"
    assert thread.created_by == ctx.user_id
    assert [%{id: id}] = Threads.list(ctx)
    assert id == thread.id

    other = user_actor("local|idp|carol", "ath_b")
    assert Threads.list(other) == []
    assert {:error, :not_found} = Threads.get(other, thread.id)

    assert {:error, :not_found} =
             Threads.append(other, thread.id, %{author: "x", content: "hi"})
  end

  test "an athanor-less actor is refused before any query, nil and empty alike", %{ctx: ctx} do
    assert {:error, :no_athanor} = Threads.list(%{ctx | athanor_id: nil})
    assert {:error, :no_athanor} = Threads.list(%{ctx | athanor_id: ""})

    # Not an actor at all: no head matches, so a context cannot be read as
    # an athanor with no threads.
    context = Sanctum.TestContext.local()
    assert_raise FunctionClauseError, fn -> Threads.list(context) end
  end

  test "messages append in seq order and the first user text titles the thread", %{
    ctx: ctx,
    bob: bob
  } do
    {:ok, thread} = Threads.create(ctx)
    assert thread.title == "New thread"

    {:ok, m1} =
      Threads.append(ctx, thread.id, %{
        author: ctx.user_id,
        content: "Plan my week\nplease"
      })

    {:ok, m2} = Threads.append(bob, thread.id, %{author: "aqua", content: "Sure."})
    {:ok, m3} = Threads.append(bob, thread.id, %{author: bob.user_id, content: "Thanks"})

    assert [m1.seq, m2.seq, m3.seq] == [1, 2, 3]

    assert Enum.map(Threads.messages(ctx, thread.id), & &1.id) == [
             m1.id,
             m2.id,
             m3.id
           ]

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

    assert {:ok, running} =
             Threads.resolve_approval(ctx, apr.id, "pending", "running")

    assert running.status == "running"
    assert running.resolved_by == ctx.user_id
    assert running.resolved_at == nil

    assert {:error, :already_resolved} =
             Threads.resolve_approval(bob, apr.id, "pending", "declined")

    assert {:ok, done} =
             Threads.resolve_approval(
               ctx,
               apr.id,
               "running",
               "approved",
               %{
                 resolution: %{"summary" => "ok"}
               }
             )

    assert done.status == "approved"
    assert done.resolved_at
    assert Threads.resolution(done) == %{"summary" => "ok"}
    assert Threads.pending_approvals(ctx, thread.id) == []

    assert {:error, :not_found} =
             Threads.resolve_approval(
               ctx,
               "msg_nope",
               "pending",
               "running"
             )
  end

  test "blob_root/1 spells a real tenant root" do
    # The module owns the "threads" literal (the layout table's
    # roster pattern: the literal lives at its single consumer, with this
    # membership witness) — a renamed row cannot silently orphan blobs.
    assert hd(Threads.blob_root("thread_x")) in Arca.Storage.tenant_roots()
  end

  test "delete removes the messages and the attachment blobs too", %{ctx: ctx} do
    {:ok, thread} = Threads.create(ctx)

    {:ok, msg} =
      Threads.append(ctx, thread.id, %{author: "aqua", content: "x"})

    blob = Threads.blob_root(thread.id) ++ [msg.id, "0-a.txt"]
    :ok = Arca.put(ctx, blob, "bytes")

    :ok = Threads.delete(ctx, thread.id)
    assert Threads.messages(ctx, thread.id) == []
    assert {:error, :not_found} = Threads.get(ctx, thread.id)
    refute Arca.exists?(ctx, blob)
  end

  test "delete goes bytes-first: a failed blob delete keeps the rows", %{ctx: ctx} do
    {:ok, thread} = Threads.create(ctx)

    {:ok, msg} =
      Threads.append(ctx, thread.id, %{author: "aqua", content: "x"})

    blob = Threads.blob_root(thread.id) ++ [msg.id, "0-a.txt"]
    :ok = Arca.put(ctx, blob, "bytes")

    prev = Application.get_env(:arca, :storage_adapter)

    Application.put_env(
      :arca,
      :storage_adapter,
      Arca.ThreadStorageTest.FailingDeleteAdapter
    )

    on_exit(fn ->
      if prev,
        do: Application.put_env(:arca, :storage_adapter, prev),
        else: Application.delete_env(:arca, :storage_adapter)
    end)

    # The DB never claims a deletion the tree didn't make.
    assert {:error, {:storage_delete_failed, :eacces}} =
             Threads.delete(ctx, thread.id)

    assert {:ok, _} = Threads.get(ctx, thread.id)
    assert [_] = Threads.messages(ctx, thread.id)

    # Healed adapter: the retry completes rows and bytes together.
    Application.put_env(:arca, :storage_adapter, prev || Arca.Adapters.Local)
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
        do:
          {:ok, _} =
            Threads.append(ctx, thread.id, %{author: "u", content: "m#{n}"})

    seqs = fn opts ->
      Threads.messages(ctx, thread.id, opts) |> Enum.map(& &1.seq)
    end

    assert seqs.([]) == [1, 2, 3, 4]
    assert seqs.(after_seq: 1) == [2, 3, 4]
    assert seqs.(after_seq: 1, upto_seq: 3) == [2, 3]
    assert seqs.(upto_seq: 2) == [1, 2]

    assert {:ok, %{turn_seq: 0, agent: nil}} = Threads.get(ctx, thread.id)

    {:ok, updated} =
      Threads.update(ctx, thread.id, %{turn_seq: 3, agent: "aqua"})

    assert updated.turn_seq == 3 and updated.agent == "aqua"
  end

  test "the reserved authors are the schema's, and neither titles a thread", %{ctx: ctx} do
    # Rows persist with these values, so the spelling is pinned as well as
    # the fact that every writer reads it from one place.
    assert Arca.Schemas.Message.agent_author() == "aqua"
    assert Arca.Schemas.Message.system_author() == "system"

    {:ok, thread} = Threads.create(ctx)

    for author <- [Arca.Schemas.Message.agent_author(), Arca.Schemas.Message.system_author()] do
      {:ok, _} =
        Threads.append(ctx, thread.id, %{
          author: author,
          kind: "text",
          content: "not a title"
        })
    end

    {:ok, still} = Threads.get(ctx, thread.id)
    refute still.title == "not a title"
  end

  test "the title drops a leading @mention but the row keeps the text as typed", %{ctx: ctx} do
    {:ok, thread} = Threads.create(ctx)

    {:ok, msg} =
      Threads.append(ctx, thread.id, %{
        author: "u",
        content: "@aqua what's the plan?"
      })

    assert msg.content == "@aqua what's the plan?"

    assert {:ok, %{title: "what's the plan?"}} =
             Threads.get(ctx, thread.id)
  end

  test "retention drops stale idle threads and keeps one holding an open turn", %{ctx: ctx} do
    {:ok, stale} = Threads.create(ctx)
    {:ok, running} = Threads.create(ctx)
    {:ok, fresh} = Threads.create(ctx)

    {:ok, _} =
      Threads.append(ctx, fresh.id, %{author: "aqua", content: "recent"})

    old = DateTime.add(DateTime.utc_now(), -400 * 86_400, :second)
    {:ok, _} = Threads.update(ctx, stale.id, %{last_message_at: old})

    {:ok, _} =
      Arca.TurnStorage.accept_message(ctx, running.id, %{
        message: %{author: ctx.user_id, content: "@aqua go"},
        turn: %{agent: "aqua", requested_by: ctx.user_id, origin: :interactive}
      })

    {:ok, _} = Threads.update(ctx, running.id, %{last_message_at: old})

    # a blob under the stale thread goes with it
    :ok =
      Arca.put(
        ctx,
        Threads.blob_root(stale.id) ++ ["msg_1", "note.txt"],
        "bytes"
      )

    cutoff = DateTime.add(DateTime.utc_now(), -365 * 86_400, :second)
    assert {:ok, 1} = Threads.delete_before(ctx, cutoff)

    refute Arca.exists?(
             ctx,
             Threads.blob_root(stale.id) ++ ["msg_1", "note.txt"]
           )

    ids = Threads.list(ctx) |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == Enum.sort([running.id, fresh.id])
  end

  test "a create over the athanor's thread cap is refused through the port, and commits nothing",
       %{ctx: ctx} do
    {:ok, _first} = Threads.create(ctx, %{title: "One"})
    before = Threads.list(ctx) |> Enum.map(& &1.id) |> Enum.sort()

    Cyfr.Test.Settings.put("max_threads_per_athanor", 1)

    # The refusal is the port's vocabulary (`Prima.Caps`), not the tenancy
    # domain named from below it, and the row it refused is not there.
    assert {:error, {:limit_reached, :max_threads_per_athanor, 1}} =
             Threads.create(ctx, %{title: "One too many"})

    assert Threads.list(ctx) |> Enum.map(& &1.id) |> Enum.sort() == before

    # Another athanor's count is its own.
    other = Prima.Actor.in_athanor("ath_b")
    assert {:ok, _} = Threads.create(other, %{title: "Theirs"})
  end
end

defmodule Arca.ThreadStorageRaceTest do
  @moduledoc """
  Creates racing for an athanor's last thread places, on connections of
  their own: inside the sandbox one shared connection would serialize
  them. On PostgreSQL every create is held behind a transaction that locks
  the athanor's row until each is seen waiting, so all of them race when
  it is let go; SQLite's one write lock admits one transaction at a time,
  so there they run as concurrent processes. The case works in an athanor
  of its own, whose rows it deletes when it ends.

  The ceiling is a stored setting, and a row written in a test's sandbox
  transaction is invisible to the creates' own connections, so it is
  written outside the sandbox too, with the node's cached value dropped
  so the creates read it, and deleted again when the case ends.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Arca.Test.Adapter, only: [postgres?: 0]

  alias Arca.PlatformSettings, as: Store
  alias Arca.QueryHelpers
  alias Arca.Schemas.{Athanor, Thread, ThreadSubscription}
  alias Arca.Test.Actor
  alias Arca.Test.LockWait
  alias Arca.ThreadStorage, as: Threads
  alias Ecto.Adapters.SQL.Sandbox

  @key "max_threads_per_athanor"
  @cap 4
  @creates 12

  setup do
    athanor = "ath_threads_race_#{System.unique_integer([:positive])}"

    unboxed(fn ->
      Actor.ensure_athanor_row(athanor)
      # The case owns the setting's row outright: it stores one and
      # deletes it, so there must be none to restore.
      {:error, :not_found} = Store.get(@key)
      {:ok, %{revision: revision}} = Store.all()
      {:ok, _} = Store.put(@key, @cap, revision, "test")
    end)

    Store.invalidate(@key)

    on_exit(fn ->
      unboxed(fn ->
        {:ok, %{revision: revision}} = Store.all()
        {:ok, _} = Store.delete(@key, revision)

        Arca.Repo.delete_all(from(s in ThreadSubscription, where: s.athanor_id == ^athanor))

        Arca.Repo.delete_all(from(t in Thread, where: t.athanor_id == ^athanor))
        Arca.Repo.delete_all(from(a in Athanor, where: a.id == ^athanor))
      end)

      Store.invalidate(@key)
    end)

    {:ok, actor: Actor.local(athanor_id: athanor)}
  end

  test "concurrent creates stop at the athanor's thread cap", %{actor: actor} do
    test = self()

    create = fn i ->
      Task.async(fn ->
        unboxed(fn ->
          if postgres?(), do: send(test, {:backend, backend_pid()})
          Threads.create(actor, %{title: "Race #{i}"})
        end)
      end)
    end

    answers =
      if postgres?() do
        # The holder also holds the threads table against inserts, so a
        # create that counted without waiting for the athanor's row still
        # waits before its row lands: every create is held, whichever
        # statement holds it, until all of them are.
        holder =
          holding(fn ->
            from(a in Athanor, where: a.id == ^actor.athanor_id)
            |> QueryHelpers.for_update()
            |> Arca.Repo.one()

            Arca.Repo.query!("LOCK TABLE threads IN SHARE MODE")
          end)

        creators = for i <- 1..@creates, do: create.(i)

        for _ <- creators do
          assert_receive {:backend, backend}, 15_000
          LockWait.await_lock_wait!(backend, [], timeout_ms: 10_000)
        end

        release(holder)
        Enum.map(creators, &Task.await(&1, 30_000))
      else
        for(i <- 1..@creates, do: create.(i)) |> Enum.map(&Task.await(&1, 30_000))
      end

    refused = {:error, {:limit_reached, :max_threads_per_athanor, @cap}}
    assert Enum.count(answers, &match?({:ok, _}, &1)) == @cap
    assert Enum.count(answers, &(&1 == refused)) == @creates - @cap

    assert unboxed(fn ->
             Arca.Repo.aggregate(
               from(t in Thread, where: t.athanor_id == ^actor.athanor_id),
               :count
             )
           end) == @cap
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  # Run `lock` in a transaction of its own and hold it open until
  # `release/1`.
  defp holding(lock) do
    test = self()

    task = Task.async(fn -> unboxed(fn -> hold(test, lock) end) end)

    assert_receive {:holding, _pid}, 15_000
    task
  end

  defp hold(test, lock) do
    Arca.Repo.transaction(fn ->
      result = lock.()
      send(test, {:holding, self()})

      receive do
        :commit -> result
      end
    end)
  end

  defp release(task) do
    send(task.pid, :commit)
    Task.await(task, 30_000)
  end

  # The backend of the current connection, so another can watch it wait.
  defp backend_pid do
    %{rows: [[pid]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
    pid
  end
end
