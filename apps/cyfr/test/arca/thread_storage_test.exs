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

  alias Arca.Test.Days
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
        provider: "passkey",
        athanor_id: athanor_id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :session,
        authenticated: true
      )
    )
  end

  defp post!(actor, thread, attrs) do
    {:ok, msg} =
      Threads.append(actor, thread.id, Map.merge(%{author: "aqua", sent_by: "aqua"}, attrs))

    msg
  end

  defp mark(actor, thread) do
    {:ok, %{read_seq: read_seq}} = Threads.get(actor, thread.id)
    read_seq
  end

  defp unread(actor, thread) do
    {:ok, thread} = Threads.get(actor, thread.id)
    {:ok, count} = Threads.unread(actor, thread)
    count
  end

  test "a thread belongs to the athanor; another athanor cannot see it", %{ctx: ctx} do
    {:ok, thread} = Days.thread(ctx)
    assert thread.athanor_id == "ath_a"
    assert thread.created_by == ctx.user_id
    assert [%{id: id}] = Threads.list(ctx)
    assert id == thread.id

    other = user_actor("local|idp|carol", "ath_b")
    assert Threads.list(other) == []
    assert {:error, :not_found} = Threads.get(other, thread.id)

    assert {:error, :not_found} =
             Threads.append(other, thread.id, %{author: "x", sent_by: "person", content: "hi"})
  end

  test "an athanor-less actor is refused before any query, nil and empty alike", %{ctx: ctx} do
    day = Days.next()

    for actor <- [%{ctx | athanor_id: nil}, %{ctx | athanor_id: ""}] do
      assert {:error, :no_athanor} = Threads.list(actor)
      assert {:error, :no_athanor} = Threads.daily(actor, day)
      assert {:error, :no_athanor} = Threads.adjacent_day(actor, day, :before)
      assert {:error, :no_athanor} = Threads.mark_read(actor, "thread_x", 1)
      assert {:error, :no_athanor} = Threads.unread(actor, %{id: "thread_x", read_seq: 0})
      assert {:error, :no_athanor} = Threads.daily_message(actor, "client-x")
    end

    # Not an actor at all: no head matches, so a context cannot be read as
    # an athanor with no threads.
    context = Sanctum.TestContext.local()
    assert_raise FunctionClauseError, fn -> Threads.list(context) end
  end

  describe "the daily thread" do
    test "is one per date of an athanor, titled with its date, and a person's text renames it not",
         %{ctx: ctx, bob: bob} do
      day = Days.next()
      {:ok, thread} = Threads.daily(ctx, day)

      assert %{kind: "daily", day: ^day, parent_id: nil, workspace_state: nil, read_seq: 0} =
               thread

      assert thread.title == Date.to_iso8601(day)
      assert thread.created_by == ctx.user_id

      # Asked again, by anyone of the athanor, the date answers the same row.
      assert {:ok, %{id: same}} = Threads.daily(bob, day)
      assert same == thread.id

      {:ok, %{id: next}} = Threads.daily(ctx, Date.add(day, 1))
      refute next == thread.id

      post!(ctx, thread, %{author: ctx.user_id, sent_by: "person", content: "Plan my week"})
      assert {:ok, %{title: title}} = Threads.get(ctx, thread.id)
      assert title == Date.to_iso8601(day)

      assert Threads.list(ctx, kind: "daily") |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([thread.id, next])
    end

    test "of another athanor is its own, the same date notwithstanding", %{ctx: ctx} do
      day = Days.next()
      {:ok, mine} = Threads.daily(ctx, day)
      other = user_actor("local|idp|carol", "ath_b")
      {:ok, theirs} = Threads.daily(other, day)

      refute theirs.id == mine.id
      assert theirs.athanor_id == "ath_b"
      assert {:ok, %{id: id}} = Threads.daily(ctx, day)
      assert id == mine.id
      assert {:error, :not_found} = Threads.get(other, mine.id)
    end

    test "nearest a date on either side is the athanor's own daily thread, and none is not found",
         %{ctx: ctx} do
      first = Days.next()
      middle = Date.add(first, 3)
      last = Date.add(first, 9)
      {:ok, before} = Threads.daily(ctx, first)
      {:ok, after_} = Threads.daily(ctx, last)

      # Another athanor's days between them, and a child thread, are no
      # neighbours of this athanor's.
      other = user_actor("local|idp|carol", "ath_b")
      {:ok, _theirs} = Threads.daily(other, Date.add(first, 1))
      {:ok, _theirs} = Threads.daily(other, Date.add(first, 5))
      {:ok, _child} = Threads.crew_thread(ctx, before.id, "planner")

      assert {:ok, %{id: id}} = Threads.adjacent_day(ctx, middle, :before)
      assert id == before.id
      assert {:ok, %{id: id}} = Threads.adjacent_day(ctx, middle, :after)
      assert id == after_.id

      # The day itself is no neighbour of its own.
      assert {:ok, %{id: id}} = Threads.adjacent_day(ctx, last, :before)
      assert id == before.id

      assert {:error, :not_found} = Threads.adjacent_day(ctx, first, :before)
      assert {:error, :not_found} = Threads.adjacent_day(ctx, last, :after)
    end
  end

  describe "a title" do
    # Workspace threads of `actor`'s athanor, written as the store writes
    # them, the first `minutes_back` minutes before now and each next one a
    # minute older.
    defp titled!(actor, titles, minutes_back) do
      now = DateTime.utc_now()

      rows =
        for {title, i} <- Enum.with_index(titles) do
          at = DateTime.add(now, -(minutes_back + i) * 60, :second)

          %{
            id: Prima.UUID7.generate_id("thread"),
            athanor_id: actor.athanor_id,
            kind: "workspace",
            workspace_state: "open",
            title: title,
            created_by: actor.user_id,
            last_message_at: at,
            inserted_at: at,
            updated_at: at
          }
        end

      {_count, _} = Arca.Repo.insert_all(Arca.Schemas.Thread, rows)
      rows
    end

    # The thread's last activity back where its row was written, after a
    # post moved it.
    defp active_at!(row) do
      Arca.Schemas.Thread
      |> Arca.Repo.get!(row.id)
      |> Ecto.Changeset.change(last_message_at: row.last_message_at)
      |> Arca.Repo.update!()
    end

    test "is found by its text folded to lower case, in no post's body and past the list's " <>
           "limit, a daily thread's by its date, and never in another athanor",
         %{ctx: ctx} do
      [moon] = titled!(ctx, ["Moon Report"], 1_000)
      newer = titled!(ctx, for(n <- 1..200, do: "Newer #{n}"), 0)
      {:ok, _} = Threads.append(ctx, moon.id, %{author: "aqua", sent_by: "aqua", content: "hi"})
      active_at!(moon)
      {:ok, daily} = Days.thread(ctx)

      other = user_actor("local|idp|carol", "ath_b")
      [theirs] = titled!(other, ["Moon Report"], 0)

      # The list's window is the 200 newest; the moon is older than all.
      refute moon.id in Enum.map(Threads.list(ctx), & &1.id)

      assert [%{id: id, title: "Moon Report"}] = Threads.list(ctx, title: "mOOn rep")
      assert id == moon.id
      assert [%{id: ^id}] = Threads.list(ctx, title: "moon", kind: "workspace", archived: false)
      assert Threads.list(ctx, title: "moon", kind: "daily") == []
      assert Threads.list(ctx, title: "moon", archived: true) == []

      assert [%{id: theirs_id}] = Threads.list(other, title: "moon")
      assert theirs_id == theirs.id

      assert [%{id: daily_id}] = Threads.list(ctx, title: Date.to_iso8601(daily.day))
      assert daily_id == daily.id

      # Every match before the limit, the latest activity first.
      found = Threads.list(ctx, title: "newer", limit: 3)
      assert Enum.map(found, & &1.id) == newer |> Enum.take(3) |> Enum.map(& &1.id)
    end

    # The rows the store answers this process's queries of threads while
    # `fun` runs: the work a search does, whatever the athanor holds.
    defp rows_read(fun) do
      handler = "thread-title-rows-#{System.unique_integer([:positive])}"
      parent = self()
      counter = :counters.new(1, [])

      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        # The event fires in the querying process; a neighbour's query is
        # not this test's.
        fn _event, _measure, meta, _config ->
          with true <- self() == parent,
               "threads" <- meta[:source],
               {:ok, %{num_rows: rows}} when is_integer(rows) <- meta[:result] do
            :counters.add(counter, 1, rows)
          end
        end,
        nil
      )

      try do
        {fun.(), :counters.get(counter, 1)}
      after
        :telemetry.detach(handler)
      end
    end

    test "is matched by the store, which reads only what it answers", %{ctx: ctx} do
      _many = titled!(ctx, for(n <- 1..450, do: "Newer #{n}"), 0)

      assert {[], 0} = rows_read(fn -> Threads.list(ctx, title: "absent") end)

      {found, read} = rows_read(fn -> Threads.list(ctx, title: "newer", limit: 3) end)
      assert length(found) == 3
      assert read == 3
    end

    test "is plain text: no character of it is a pattern", %{ctx: ctx} do
      [sale] = titled!(ctx, ["50%_off!"], 0)
      _plain = titled!(ctx, ["500 off", "5 of 0"], 1)

      assert [%{id: id}] = Threads.list(ctx, title: "%_")
      assert id == sale.id
      assert [%{id: ^id}] = Threads.list(ctx, title: "0%_O")
      assert Threads.list(ctx, title: "5%") == []
      assert Threads.list(ctx, title: "_") |> Enum.map(& &1.id) == [id]
    end
  end

  describe "the read mark" do
    test "moves forward only, never past the last message, and answers where it stands", %{
      ctx: ctx
    } do
      {:ok, thread} = Days.thread(ctx)

      # Nothing to read: the mark stays at 0.
      assert {:ok, 0} = Threads.mark_read(ctx, thread.id, 5)

      for n <- 1..4, do: post!(ctx, thread, %{content: "m#{n}"})

      assert {:ok, 2} = Threads.mark_read(ctx, thread.id, 2)
      assert mark(ctx, thread) == 2

      # A lower mark leaves it.
      assert {:ok, 2} = Threads.mark_read(ctx, thread.id, 1)
      assert {:ok, 2} = Threads.mark_read(ctx, thread.id, 0)
      assert mark(ctx, thread) == 2

      # A mark past the last message marks the last.
      assert {:ok, 4} = Threads.mark_read(ctx, thread.id, 100)
      assert mark(ctx, thread) == 4
    end

    test "of another athanor's thread is not found and moves nothing", %{ctx: ctx} do
      {:ok, thread} = Days.thread(ctx)
      for n <- 1..3, do: post!(ctx, thread, %{content: "m#{n}"})
      {:ok, 1} = Threads.mark_read(ctx, thread.id, 1)

      other = user_actor("local|idp|carol", "ath_b")
      assert {:error, :not_found} = Threads.mark_read(other, thread.id, 3)
      assert mark(ctx, thread) == 1

      assert {:error, :not_found} = Threads.mark_read(ctx, "thread_nothing", 1)
    end
  end

  describe "the unread count" do
    test "counts the posts past the mark the person did not send, a server-voiced line among them",
         %{ctx: ctx} do
      {:ok, thread} = Days.thread(ctx)

      # The person's own line is read by its sender.
      post!(ctx, thread, %{author: ctx.user_id, sent_by: "person", content: "@aqua plan"})
      assert unread(ctx, thread) == 0

      # A turn's own rows are no posts, whoever wrote them.
      for kind <- ~w(tool_call tool_result compaction turn_aborted),
          do: post!(ctx, thread, %{kind: kind, content: kind})

      assert unread(ctx, thread) == 0

      # The agent's reply and its error.
      post!(ctx, thread, %{content: "Here is the plan."})
      post!(ctx, thread, %{kind: "error", content: "It failed."})
      assert unread(ctx, thread) == 2

      # A schedule's line is sent for its person in the server's voice: the
      # person did not write it, so it counts.
      line =
        post!(ctx, thread, %{
          author: Prima.Author.system(),
          sent_by: "person",
          kind: "text",
          content: "Morning summary"
        })

      assert unread(ctx, thread) == 3

      # A crew member's reply is not the person's either.
      post!(ctx, thread, %{author: "planner", sent_by: "planner", content: "Done."})
      assert unread(ctx, thread) == 4

      {:ok, _} = Threads.mark_read(ctx, thread.id, line.seq)
      assert unread(ctx, thread) == 1

      {:ok, _} = Threads.mark_read(ctx, thread.id, line.seq + 1)
      assert unread(ctx, thread) == 0
    end

    test "is the athanor's own: another athanor counts none of it", %{ctx: ctx} do
      {:ok, thread} = Days.thread(ctx)
      post!(ctx, thread, %{content: "Here is the plan."})
      assert unread(ctx, thread) == 1

      other = user_actor("local|idp|carol", "ath_b")
      assert {:ok, 0} = Threads.unread(other, %{id: thread.id, read_seq: 0})
    end
  end

  describe "a message by its client id across the daily threads" do
    test "is found in whichever daily thread of the athanor holds it, and nowhere else", %{
      ctx: ctx
    } do
      {:ok, yesterday} = Days.thread(ctx)
      {:ok, today} = Days.thread(ctx)
      {:ok, child} = Threads.crew_thread(ctx, today.id, "planner")

      held = post!(ctx, yesterday, %{client_id: "c-yesterday", content: "late"})
      post!(ctx, today, %{client_id: "c-today", content: "now"})
      post!(ctx, child, %{client_id: "c-crew", content: "in the crew's"})

      assert {:ok, %{id: id, thread_id: thread_id}} = Threads.daily_message(ctx, "c-yesterday")
      assert {id, thread_id} == {held.id, yesterday.id}
      assert {:ok, %{thread_id: thread_id}} = Threads.daily_message(ctx, "c-today")
      assert thread_id == today.id

      # A child thread is no daily thread.
      assert {:error, :not_found} = Threads.daily_message(ctx, "c-crew")
      assert {:error, :not_found} = Threads.daily_message(ctx, "c-nothing")

      # Another athanor finds none of it, even holding the same client id.
      other = user_actor("local|idp|carol", "ath_b")
      assert {:error, :not_found} = Threads.daily_message(other, "c-yesterday")
      {:ok, theirs} = Days.thread(other)
      post!(other, theirs, %{client_id: "c-today", content: "theirs"})
      assert {:ok, %{thread_id: thread_id}} = Threads.daily_message(ctx, "c-today")
      assert thread_id == today.id
    end

    test "held by two daily threads names no one message", %{ctx: ctx} do
      {:ok, one} = Days.thread(ctx)
      {:ok, two} = Days.thread(ctx)
      post!(ctx, one, %{client_id: "c-twice", content: "a"})
      post!(ctx, two, %{client_id: "c-twice", content: "b"})

      assert {:error, :not_found} = Threads.daily_message(ctx, "c-twice")
    end
  end

  test "messages append in seq order", %{ctx: ctx, bob: bob} do
    {:ok, thread} = Days.thread(ctx)

    {:ok, m1} =
      Threads.append(ctx, thread.id, %{
        author: ctx.user_id,
        sent_by: "person",
        content: "Plan my week\nplease"
      })

    {:ok, m2} =
      Threads.append(bob, thread.id, %{author: "aqua", sent_by: "aqua", content: "Sure."})

    {:ok, m3} =
      Threads.append(bob, thread.id, %{author: bob.user_id, sent_by: "person", content: "Thanks"})

    assert [m1.seq, m2.seq, m3.seq] == [1, 2, 3]

    assert Enum.map(Threads.messages(ctx, thread.id), & &1.id) == [
             m1.id,
             m2.id,
             m3.id
           ]

    {:ok, thread} = Threads.get(ctx, thread.id)
    assert thread.last_message_at
  end

  test "a payload round-trips as JSON", %{ctx: ctx} do
    {:ok, thread} = Days.thread(ctx)

    {:ok, msg} =
      Threads.append(ctx, thread.id, %{
        author: "aqua",
        sent_by: "aqua",
        payload: %{"intent" => %{"title" => "t"}}
      })

    assert Threads.payload(msg) == %{"intent" => %{"title" => "t"}}
  end

  test "blob_root/1 spells a real tenant root" do
    # The module owns the "threads" literal (the layout table's
    # roster pattern: the literal lives at its single consumer, with this
    # membership witness) — a renamed row cannot silently orphan blobs.
    assert hd(Threads.blob_root("thread_x")) in Arca.Storage.tenant_roots()
  end

  test "delete removes the messages and the attachment blobs too", %{ctx: ctx} do
    {:ok, thread} = Days.thread(ctx)

    {:ok, msg} =
      Threads.append(ctx, thread.id, %{author: "aqua", sent_by: "aqua", content: "x"})

    blob = Threads.blob_root(thread.id) ++ [msg.id, "0-a.txt"]
    :ok = Arca.put(ctx, blob, "bytes")

    {:ok, %{cancelled: []}} = Threads.delete(ctx, thread.id)
    assert Threads.messages(ctx, thread.id) == []
    assert {:error, :not_found} = Threads.get(ctx, thread.id)
    refute Arca.exists?(ctx, blob)
  end

  test "a deleted daily thread frees its date: the next call makes the day anew", %{ctx: ctx} do
    day = Days.next()
    {:ok, gone} = Threads.daily(ctx, day)
    post!(ctx, gone, %{content: "x"})
    {:ok, %{cancelled: []}} = Threads.delete(ctx, gone.id)

    assert {:ok, again} = Threads.daily(ctx, day)
    refute again.id == gone.id
    assert again.day == day
    assert Threads.messages(ctx, again.id) == []
  end

  test "delete commits the rows before the bytes: a failed blob delete leaves them to the sweep",
       %{ctx: ctx} do
    {:ok, thread} = Days.thread(ctx)

    {:ok, msg} =
      Threads.append(ctx, thread.id, %{author: "aqua", sent_by: "aqua", content: "x"})

    blob = Threads.blob_root(thread.id) ++ [msg.id, "0-a.txt"]
    :ok = Arca.put(ctx, blob, "bytes")

    # The tree refuses after the commit: the deletion stands.
    assert {:ok, %{cancelled: []}} =
             Prima.Test.Env.with_app_env(
               :arca,
               :storage_adapter,
               Arca.ThreadStorageTest.FailingDeleteAdapter,
               fn -> Threads.delete(ctx, thread.id) end
             )

    assert {:error, :not_found} = Threads.get(ctx, thread.id)
    assert Threads.messages(ctx, thread.id) == []
    assert Arca.exists?(ctx, blob)

    # No row backs the bytes, so the retention sweep reclaims them.
    assert {:ok, reclaimed} = Threads.sweep_orphaned_blobs(ctx)
    assert reclaimed >= 1
    refute Arca.exists?(ctx, blob)
  end

  test "sweep_orphaned_blobs/1 reclaims rowless dirs and keeps live ones", %{ctx: ctx} do
    {:ok, thread} = Days.thread(ctx)
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
    {:ok, thread} = Days.thread(ctx)

    for n <- 1..4,
        do:
          {:ok, _} =
            Threads.append(ctx, thread.id, %{author: "u", sent_by: "person", content: "m#{n}"})

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

  test "the reserved authors are the schema's" do
    # Rows persist with these values, so the spelling is pinned as well as
    # the fact that every writer reads it from one place.
    assert Arca.Schemas.Message.agent_author() == "aqua"
    assert Arca.Schemas.Message.system_author() == "system"
  end

  test "the setting archives an idle thread, its files kept, and leaves one holding an open turn and a fresh one",
       %{ctx: ctx} do
    {:ok, stale} = Days.thread(ctx)
    {:ok, running} = Days.thread(ctx)
    {:ok, fresh} = Days.thread(ctx)

    {:ok, _} =
      Threads.append(ctx, fresh.id, %{author: "aqua", sent_by: "aqua", content: "recent"})

    old = DateTime.add(DateTime.utc_now(), -400 * 86_400, :second)
    {:ok, _} = Threads.update(ctx, stale.id, %{last_message_at: old})

    {:ok, _} =
      Arca.TurnStorage.accept_message(ctx, running.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "@aqua go"},
        turn: %{agent: "aqua", requested_by: ctx.user_id, origin: :interactive}
      })

    {:ok, _} = Threads.update(ctx, running.id, %{last_message_at: old})

    # a blob under the idle thread stays with it
    :ok =
      Arca.put(
        ctx,
        Threads.blob_root(stale.id) ++ ["msg_1", "note.txt"],
        "bytes"
      )

    cutoff = DateTime.add(DateTime.utc_now(), -365 * 86_400, :second)
    assert {:ok, 1} = Threads.count_idle(ctx, cutoff)
    assert {:ok, 1} = Threads.archive_idle(ctx, cutoff)

    assert Arca.exists?(
             ctx,
             Threads.blob_root(stale.id) ++ ["msg_1", "note.txt"]
           )

    assert Enum.map(Threads.list(ctx, archived: true), & &1.id) == [stale.id]
    ids = Threads.list(ctx, archived: false) |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == Enum.sort([running.id, fresh.id])
  end
end

defmodule Arca.ThreadStorageRaceTest do
  @moduledoc """
  Callers racing for an athanor's daily threads, on connections of their
  own: inside the sandbox one shared connection would serialize them. On
  PostgreSQL every caller is held behind a transaction that holds a lock
  it must pass until each is seen waiting, so all of them race when it is
  let go; SQLite's one write lock admits one transaction at a time, so
  there they run as concurrent processes. Each case works in an athanor
  of its own, whose rows it deletes when it ends.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Arca.Test.Adapter, only: [postgres?: 0]

  alias Arca.QueryHelpers
  alias Arca.Schemas.{Athanor, Thread}
  alias Arca.Test.Actor
  alias Arca.Test.LockWait
  alias Arca.ThreadStorage, as: Threads
  alias Ecto.Adapters.SQL.Sandbox

  @callers 12

  setup do
    n = System.unique_integer([:positive])
    athanor = "ath_threads_race_#{n}"
    # An athanor no row stands for: nothing to lock, so the index alone
    # holds its days.
    rowless = "ath_threads_race_rowless_#{n}"

    unboxed(fn -> Actor.ensure_athanor_row(athanor) end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(from(t in Thread, where: t.athanor_id in ^[athanor, rowless]))
        Arca.Repo.delete_all(from(a in Athanor, where: a.id == ^athanor))
      end)
    end)

    {:ok, actor: Actor.local(athanor_id: athanor), rowless: Actor.local(athanor_id: rowless)}
  end

  test "concurrent callers of one day make one daily thread, and every one is answered it", %{
    actor: actor
  } do
    day = Arca.Test.Days.next()

    answers =
      race(fn _i -> Threads.daily(actor, day) end, fn ->
        lock_athanor_row(actor)
        lock_thread_inserts()
      end)

    assert [{:ok, %{id: id, day: ^day}} | _] = answers
    assert Enum.all?(answers, &match?({:ok, %{id: ^id}}, &1)), inspect(answers)
    assert rows(actor) == 1
  end

  test "in an athanor with no row to lock, the callers that lose a day's index read the winner's",
       %{rowless: actor} do
    day = Arca.Test.Days.next()

    # Each caller has looked for the day and found none before the holder
    # lets its insert go, so on PostgreSQL every one but the first meets
    # the index.
    answers = race(fn _i -> Threads.daily(actor, day) end, &lock_thread_inserts/0, ["INSERT"])

    assert [{:ok, %{id: id, day: ^day}} | _] = answers
    assert Enum.all?(answers, &match?({:ok, %{id: ^id}}, &1)), inspect(answers)
    assert rows(actor) == 1
  end

  # `@callers` calls of `call`, each on a connection of its own. On
  # PostgreSQL they wait behind `hold`, taken first in a transaction of its
  # own, until every caller is seen waiting on a lock in a statement
  # holding `fragments`, and are let go together.
  defp race(call, hold, fragments \\ []) do
    test = self()

    start = fn i ->
      Task.async(fn ->
        unboxed(fn ->
          if postgres?(), do: send(test, {:backend, backend_pid()})
          call.(i)
        end)
      end)
    end

    if postgres?() do
      holder = holding(hold)
      callers = for i <- 1..@callers, do: start.(i)

      for _ <- callers do
        assert_receive {:backend, backend}, 15_000
        LockWait.await_lock_wait!(backend, fragments, timeout_ms: 10_000)
      end

      release(holder)
      Enum.map(callers, &Task.await(&1, 30_000))
    else
      for(i <- 1..@callers, do: start.(i)) |> Enum.map(&Task.await(&1, 30_000))
    end
  end

  defp lock_athanor_row(actor) do
    from(a in Athanor, where: a.id == ^actor.athanor_id)
    |> QueryHelpers.for_update()
    |> Arca.Repo.one()
  end

  # Reads pass the table's SHARE lock and inserts wait on it, so a caller
  # that looked without waiting for the athanor's row still waits before
  # its row lands.
  defp lock_thread_inserts, do: Arca.Repo.query!("LOCK TABLE threads IN SHARE MODE")

  defp rows(actor) do
    unboxed(fn ->
      Arca.Repo.aggregate(from(t in Thread, where: t.athanor_id == ^actor.athanor_id), :count)
    end)
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
