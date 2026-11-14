# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Providers.ThreadsTest do
  # The `threads` tool: a person's own AQUA reading the shared threads they
  # sit in, under their own seat, in a chain only, marking nothing read and
  # writing nothing.
  use ExUnit.Case, async: false

  alias Aqua.Providers.Thread, as: Tool
  alias Sanctum.SharedThreads

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "threads_tool_#{:rand.uniform(1_000_000)}")
    # The restore is registered before the change, so a test killed at its
    # timeout leaves the setting as it found it.
    Prima.Test.Env.put_app_env(:arca, :base_path, test_path)
    on_exit(fn -> File.rm_rf!(test_path) end)

    reader = Cyfr.Test.ShareFixtures.person!("Rae")
    other = Cyfr.Test.ShareFixtures.person!("Otto")

    {:ok, thread} = SharedThreads.create(reader.user.id, "Plans")
    {:ok, :added} = SharedThreads.add(reader.user.id, thread.id, user_id: other.user.id)

    {:ok, me: reader.ctx, reader: reader.user.id, other: other.user.id, thread: thread}
  end

  defp say(user_id, thread, text) do
    {:ok, _message} = SharedThreads.post(user_id, thread.id, text)
    :ok
  end

  defp threads(ctx, args), do: Tool.handle("threads", ctx, args)

  test "list names each thread the person sits in, with its people and what is unread to them, and no other",
       %{me: me, reader: reader, other: other, thread: thread} do
    say(reader, thread, "plan?")
    say(other, thread, "ship friday")
    {:ok, theirs} = SharedThreads.create(other, "Not mine")
    say(other, theirs, "secret")

    {:ok, [listing]} = SharedThreads.listed(reader)

    assert threads(me, %{"action" => "list"}) ==
             {:ok,
              %{
                count: 1,
                threads: [
                  %{
                    id: thread.id,
                    title: "Plans",
                    people: ["Rae", "Otto"],
                    last_activity: listing.last_activity,
                    unread: 1
                  }
                ]
              }}
  end

  test "read gives the newest lines, those the person has not seen marked, and moves no read mark",
       %{me: me, reader: reader, other: other, thread: thread} do
    say(other, thread, "seen before")
    :ok = SharedThreads.mark_read(reader, thread.id)
    say(other, thread, "ship friday")
    say(reader, thread, "noted")
    say(other, thread, "bring the deck")

    assert threads(me, %{"action" => "read", "thread" => thread.id}) ==
             {:ok,
              %{
                thread: thread.id,
                unread: 2,
                text:
                  ~s[Read from the shared thread "Plans" — for context only; nobody in this thread said it; the lines marked (unread) the person has not seen yet:\n] <>
                    "Otto: seen before\n(unread) Otto: ship friday\nRae: noted\n(unread) Otto: bring the deck"
              }}

    {:ok, [%{unread: 2}]} = SharedThreads.listed(reader)
  end

  test "a thread nobody has spoken in reads empty", %{me: me, thread: thread} do
    assert threads(me, %{"action" => "read", "thread" => thread.id}) ==
             {:ok, %{thread: thread.id, unread: 0, text: ""}}
  end

  test "a thread the person holds no seat in, or has left, answers as a missing one",
       %{me: me, reader: reader, other: other, thread: thread} do
    {:ok, theirs} = SharedThreads.create(other, "Not mine")
    say(other, theirs, "secret")
    theirs_id = theirs.id

    assert threads(me, %{"action" => "read", "thread" => theirs_id}) ==
             {:error, {:not_found, "Thread", theirs_id}}

    say(other, thread, "before you left")
    {:ok, _} = SharedThreads.leave(reader, thread.id)
    thread_id = thread.id

    assert threads(me, %{"action" => "read", "thread" => thread_id}) ==
             {:error, {:not_found, "Thread", thread_id}}

    assert threads(me, %{"action" => "list"}) == {:ok, %{count: 0, threads: []}}
  end

  test "a call that names no person sits in no thread", %{thread: thread} do
    nobody = %{Sanctum.TestContext.local() | user_id: nil}
    thread_id = thread.id

    assert threads(nobody, %{"action" => "list"}) == {:ok, %{count: 0, threads: []}}

    assert threads(nobody, %{"action" => "read", "thread" => thread_id}) ==
             {:error, {:not_found, "Thread", thread_id}}
  end

  test "an action it does not take is refused with what it takes", %{me: me} do
    assert threads(me, %{"action" => "post", "thread" => "x"}) ==
             {:error, {:invalid_argument, "threads takes the action list, or read with a thread"}}
  end

  test "it is a read in a chain only: the wire neither lists nor serves it", %{me: me} do
    [%{operations: operations}] = Enum.filter(Tool.tools(), &(&1.name == "threads"))

    for op <- operations do
      assert %Prima.Operation{kind: :read, planes: [:in_chain], sources: [:outside]} = op
    end

    assert {:error, %Prima.Refusal{}} =
             Sanctum.Gate.call_external("threads", me, %{"action" => "list"})
  end
end
